--[[
KOAssistant Setup Wizard v2 (wizard_onboarding_plan.md, built 2026-08-11).

INERT UNTIL RELEASE: no user-facing entry routes here yet. The old wizard in
main.lua keeps serving first-run (`checkSetupWizard`) and the "Re-run Setup
Wizard" row untouched; this module's only entry is the debug-gated
"Setup Wizard v2 (dev)" row (Settings > Advanced, visible with Console Debug
on). The release flip is: point `checkSetupWizard` at
`SetupWizard.runChain(plugin, {mark_complete = true})` and `rerunSetupWizard`
at `SetupWizard.showTopicMenu(plugin)`.

Steps are FUNCTIONS with per-step "configured?" PROBES, so one implementation
serves both first-run onboarding and the completer re-run (maintainer
2026-08-11: the wizard must respect what is already set — never re-ask, only
offer change). The topic menu runs any single step with `force = true`.

Font install target (maintainer rule 2026-08-11): the user koreader folder's
fonts/ everywhere KOReader scans it — that is `data_dir/fonts` (the install
dir on e-ink/PocketBook, <external storage>/koreader/fonts on Android).
Desktop mac/linux is the lone exception: KOReader does not scan its data dir
there, so we use KOReader's own designated user font dir (first
FontSettings:getPath() entry). Both branches call KOReader's functions; no
paths of our own. We never touch system font locations.

Everything the wizard writes into KOReader-owned state is RECORDED in plugin
settings for precise undo (features._wizard_font_install /
_wizard_gesture_writes — registered in the storage registry's internal
bucket): the full-reset audit item.
]]

local logger = require("koassistant.core.logger")
local _ = require("koassistant.core.gettext")
local T = require("ffi/util").template

local SetupWizard = {}

-- The plugin's root folder (for the bundled font), without a trailing slash
local PLUGIN_DIR = (require("koassistant.core.paths").ROOT:gsub("/$", ""))

SetupWizard.FONT_FILE = "NotoEmoji-Regular.ttf"
-- Mirrors Font.additional_fallback_max_nb (KOReader ui/font.lua); the
-- fallback list is shared with the user's own language fallbacks — never
-- evict, only inform (plan §2 cap-full rule).
SetupWizard.FALLBACK_MAX = 4

-- Curated picker for the connect step: the maintained providers a fresh user
-- should choose from (brand names untranslated). Community providers and
-- custom endpoints stay in Settings — the wizard names the door instead.
SetupWizard.PROVIDER_CHOICES = {
    { id = "anthropic",  name = "Anthropic" },
    { id = "openai",     name = "OpenAI" },
    { id = "gemini",     name = "Google Gemini" },
    { id = "deepseek",   name = "DeepSeek" },
    { id = "mistral",    name = "Mistral" },
    { id = "xai",        name = "xAI (Grok)" },
    { id = "openrouter", name = "OpenRouter" },
    { id = "zai",        name = "Z.AI" },
    { id = "perplexity", name = "Perplexity" },
    { id = "ollama",     name = "Ollama (local)" },
}

-- The update check (the wizard's second face, 2026-10-19): the steps a
-- release asks an existing install to look at, by version (the base version,
-- "-dev" dropped). A version with no entry runs no check; the stamp
-- features._wizard_version is written anyway, so a later release with one
-- fires once. Adding a step to a release = one function in CHAIN, its probe,
-- its key here and a line in NOTES (runUpdate).
SetupWizard.UPDATE_STEPS = {
    ["0.24.0"] = { "privacy", "icons", "gestures" },
}

--========================================================================--
--  Pure helpers (unit-tested in tests/unit/test_setup_wizard.lua;
--  no KOReader state, everything injected)
--========================================================================--

-- Where the emoji font goes. opts = { is_desktop, data_dir, user_font_path }
-- (user_font_path = FontSettings:getPath(), possibly semicolon-joined).
function SetupWizard.resolveFontDir(opts)
    if opts.is_desktop then
        local first = opts.user_font_path and opts.user_font_path:match("[^;]+")
        if first and first ~= "" then
            return first
        end
    end
    return opts.data_dir .. "/fonts"
end

-- Append a font path to a font_ui_fallbacks list (KOReader semantics: new
-- entries go to position 1 of the additional list). Returns the new list,
-- or nil + reason ("present" | "cap"). Never mutates the input.
function SetupWizard.appendFallback(list, path, max_nb)
    local fname = path:match("[^/]+$")
    local out = {}
    for i = 1, #(list or {}) do
        local entry = list[i]
        if entry:match("[^/]+$") == fname then
            return nil, "present"
        end
        out[i] = entry
    end
    if #out >= (max_nb or SetupWizard.FALLBACK_MAX) then
        return nil, "cap"
    end
    table.insert(out, 1, path)
    return out
end

-- Registered emoji fallback in a font_ui_fallbacks list? Returns the path.
function SetupWizard.findEmojiFallback(list)
    for i = 1, #(list or {}) do
        if list[i]:match("[^/]+$") == SetupWizard.FONT_FILE then
            return list[i]
        end
    end
    return nil
end

-- The emoji font's state for the Emoji Font row in Settings (B397):
-- "missing" (not registered, or the registered file is gone), "restart"
-- (registered, but KOReader reads the list at startup and has not loaded
-- it), "installed".
function SetupWizard.fontState(registered_path, file_exists, loaded)
    if not registered_path or not file_exists then
        return "missing"
    end
    if not loaded then
        return "restart"
    end
    return "installed"
end

function SetupWizard.fontRowLabel(state)
    if state == "installed" then
        return _("Emoji Font: Installed")
    elseif state == "restart" then
        return _("Emoji Font: Restart KOReader")
    end
    return _("Emoji Font: Not Installed")
end

function SetupWizard.probeLanguageF(features)
    if features.interaction_languages and #features.interaction_languages > 0 then
        return true, features.interaction_languages[1]
    end
    if features.user_languages and features.user_languages ~= "" then
        return true, features.user_languages
    end
    return false
end

-- Privacy counts as configured when the reader decided: a preset was picked
-- or Ask kept (the stamp features._privacy_decided, written by main.lua's
-- applyPrivacyPreset and the update face's Keep Ask; Default (Ask) clears
-- every key, so the keys alone cannot tell a decision from a fresh install),
-- or any of the consent keys is explicitly present (a value set by hand; an
-- explicit false is as much a decision as a true). The detail is the preset
-- the values match (Default (Ask), Allow everything, Block everything, Custom).
local PRIVACY_KEYS = {
    "enable_highlights_sharing", "enable_annotations_sharing",
    "enable_notebook_sharing", "enable_basic_stats", "enable_advanced_stats",
    "enable_book_text_extraction", "enable_library_scanning", "nearby_text_sharing",
}
function SetupWizard.probePrivacyF(features)
    local decided = features._privacy_decided == true
    if not decided then
        for _idx, key in ipairs(PRIVACY_KEYS) do
            if features[key] ~= nil then decided = true; break end
        end
    end
    if not decided then return false end
    local Gates = require("koassistant.request.privacy_gates")
    return true, require("koassistant.ui.data_access").presetLabel(Gates.presetOf(features))
end

-- The (KOA) mark on KOAssistant's buttons (B511): three per-surface keys
-- (Constants.KOA_SUFFIX_KEYS, shown unless false). Decided when any of them
-- is explicitly present; Show the mark writes true, so a kept default reads
-- as a decision (the privacy stamp's lesson). The detail says where it shows.
function SetupWizard.probeMarksF(features)
    local Constants = require("koassistant.core.constants")
    local decided, shown, total = false, 0, 0
    for _surface, key in pairs(Constants.KOA_SUFFIX_KEYS) do
        total = total + 1
        if features[key] ~= nil then decided = true end
        if features[key] ~= false then shown = shown + 1 end
    end
    local detail
    if shown == total then
        detail = _("shown")
    elseif shown == 0 then
        detail = _("hidden")
    else
        detail = T(_("shown in %1 of %2 menus"), shown, total)
    end
    return decided, detail
end

--- The providers with a usable key: a GUI key or an apikeys.lua key that is
--- not the placeholder (a multi-key entry counts when it holds anything),
--- plus the OpenAI Subscription when its token is present. Sorted. Pure.
function SetupWizard.keyedProviders(gui_keys, file_keys, has_oauth, is_placeholder)
    local seen, out = {}, {}
    local function add(provider, key)
        if seen[provider] or type(provider) ~= "string" then return end
        local keyed = (type(key) == "string" and not is_placeholder(key))
            or (type(key) == "table" and next(key) ~= nil)
        if keyed then
            seen[provider] = true
            out[#out + 1] = provider
        end
    end
    for provider, key in pairs(gui_keys or {}) do add(provider, key) end
    for provider, key in pairs(file_keys or {}) do add(provider, key) end
    if has_oauth and not seen.openai_codex then out[#out + 1] = "openai_codex" end
    table.sort(out)
    return out
end

-- gui_keys = features.api_keys, file_keys = decoded apikeys.lua table (or
-- nil), has_oauth = codex token present, is_placeholder = predicate;
-- opts.main = the main chat provider's id, opts.name(id) = a display name.
-- The detail names the main provider when it has a key, else the first keyed
-- one, and how many more have one ("Anthropic and 2 more").
function SetupWizard.probeProviderF(gui_keys, file_keys, has_oauth, is_placeholder, opts)
    local keyed = SetupWizard.keyedProviders(gui_keys, file_keys, has_oauth, is_placeholder)
    opts = opts or {}
    local name = opts.name or function(id) return (id:gsub("^%l", string.upper)) end
    if #keyed == 0 then
        -- a main provider that needs no key (Ollama, a local custom provider)
        if opts.keyless_main and type(opts.main) == "string" then return true, name(opts.main) end
        return false
    end
    local first = keyed[1]
    for _idx, id in ipairs(keyed) do
        if id == opts.main then first = id end
    end
    if #keyed == 1 then return true, name(first) end
    return true, T(_("%1 and %2 more"), name(first), #keyed - 1)
end

-- Any KOAssistant action bound in a gestures table? Returns count + a
-- description of the first hit. Entry tables may carry a "settings"
-- ordering subtable — that key is not an action.
function SetupWizard.scanGestures(gestures_data)
    local count, first = 0, nil
    for _idx, section_name in ipairs({ "gesture_reader", "gesture_fm" }) do
        local section = (gestures_data or {})[section_name]
        if type(section) == "table" then
            for slot, entry in pairs(section) do
                if type(entry) == "table" then
                    for action_id in pairs(entry) do
                        if type(action_id) == "string" and action_id:find("^koassistant") then
                            count = count + 1
                            first = first or (action_id .. " @ " .. slot)
                            break
                        end
                    end
                end
            end
        end
    end
    return count, first
end

-- Free/taken state of one gesture slot entry.
function SetupWizard.slotState(entry)
    if entry == nil or (type(entry) == "table" and next(entry) == nil) then
        return "free", 0
    end
    local n = 0
    if type(entry) == "table" then
        for k in pairs(entry) do
            if k ~= "settings" then n = n + 1 end
        end
    end
    return "taken", n
end

--- "0.24.0-dev" and "0.24.0" are one version here.
function SetupWizard.baseVersion(v)
    return (tostring(v or ""):gsub("%-.*$", ""))
end

--- Which face an install gets at the first interaction (pure): "fresh"
--- (nothing set up: the welcome chain), "update" (a configured install, this
--- version lists update steps and the stamp is older) or "none". completed =
--- the completion stamp of either wizard, configured = the provider probe,
--- last_version = features._wizard_version (the old wizard wrote none).
function SetupWizard.faceFor(completed, configured, last_version, this_version, update_steps)
    if not completed and not configured then return "fresh" end
    local base = SetupWizard.baseVersion(this_version)
    local steps = update_steps and update_steps[base]
    if steps and #steps > 0 and SetupWizard.baseVersion(last_version) ~= base then return "update" end
    return "none"
end

--- The icons step's branch in the update check (pure): icons_on = any icon
--- switch on, font_state from readFontState. "test" = the glyph test,
--- "install" = the font offer, "restart" = the restart ask, "offer" = ask to
--- turn the icons on (the font installs with them).
function SetupWizard.iconsPlan(icons_on, font_state)
    if not icons_on then return "offer" end
    if font_state == "installed" then return "test" end
    if font_state == "restart" then return "restart" end
    return "install"
end

--- Whether the chain runs a step (pure). In an update check the listed
--- steps run, forced, plus any CONFIGURE step its probe says is not set;
--- welcome and restore belong to the fresh face; finish always runs. In the
--- fresh chain every step runs and decides for itself (its probe, or force).
--- @return boolean run, boolean forced
function SetupWizard.shouldRun(key, opts, configured)
    opts = opts or {}
    if key == "finish" then return true, opts.force or false end
    if opts.update then
        if key == "welcome" or key == "restore" then return false, false end
        if opts.only and opts.only[key] then return true, true end
        return not configured, false
    end
    return true, opts.force or false
end

--========================================================================--
--  Live state readers
--========================================================================--

local function feats(plugin)
    return plugin.settings:readSetting("features") or {}
end

local function saveFeats(plugin, features)
    plugin.settings:saveSetting("features", features)
    plugin.settings:flush()
end

-- The emoji font as KOReader sees it now: registered in font_ui_fallbacks,
-- its file present, and loaded into Font.fallbacks (read once at startup, so
-- a fresh install waits for the restart). Returns the state and the path.
function SetupWizard.readFontState()
    local registered = G_reader_settings
        and SetupWizard.findEmojiFallback(G_reader_settings:readSetting("font_ui_fallbacks"))
    local exists, loaded = false, false
    if registered then
        local lfs = require("libs/libkoreader-lfs")
        exists = lfs.attributes(registered, "mode") ~= nil
        local ok, Font = pcall(require, "ui/font")
        local fallbacks = (ok and type(Font) == "table") and Font.fallbacks or {}
        for _idx, path in ipairs(fallbacks) do
            if path == registered then
                loaded = true
                break
            end
        end
    end
    return SetupWizard.fontState(registered, exists, loaded), registered
end

local function fontInstallDir()
    local Device = require("device")
    local DataStorage = require("datastorage")
    local is_desktop = Device:isDesktop() or Device:isEmulator()
    local user_path
    if is_desktop then
        local ok, FontSettings = pcall(require, "ui/elements/font_settings")
        if ok and FontSettings then
            local ok2, path = pcall(function() return FontSettings:getPath() end)
            user_path = ok2 and path or nil
        end
    end
    return SetupWizard.resolveFontDir({
        is_desktop = is_desktop,
        data_dir = DataStorage:getDataDir(),
        user_font_path = user_path,
    })
end

local function readFileApiKeys()
    local path = PLUGIN_DIR .. "/apikeys.lua"
    local lfs = require("libs/libkoreader-lfs")
    if not lfs.attributes(path, "mode") then return nil end
    local ok, keys = pcall(dofile, path)
    if ok and type(keys) == "table" then return keys end
    return nil
end

local function readGesturesData(plugin)
    -- Prefer the live Gestures plugin instance (its settings object is
    -- class-level, shared by reader and file-browser instances).
    local ges = plugin.ui and plugin.ui.gestures
    if ges and ges.settings and ges.settings.data then
        return ges.settings.data, ges.settings
    end
    local DataStorage = require("datastorage")
    local LuaSettings = require("luasettings")
    local settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/gestures.lua")
    settings.data = settings.data or {}
    return settings.data, settings
end

-- Raw probes (ignore the pretend flag). Each returns configured, detail.
local function probeRaw(plugin, name)
    local f = feats(plugin)
    if name == "language" then
        return SetupWizard.probeLanguageF(f)
    elseif name == "provider" then
        local Base = require("koassistant.api.base")
        local has_oauth = type(f.openai_codex_oauth) == "table"
            and next(f.openai_codex_oauth) ~= nil
        local main = require("koassistant.core.config_helper").mainProvider(f)
        return SetupWizard.probeProviderF(f.api_keys, readFileApiKeys(),
            has_oauth, Base.isPlaceholderKey, {
                main = main,
                -- Ollama and a local custom provider need no key
                keyless_main = main ~= "openai_codex" and plugin.isProviderConfigured ~= nil
                    and plugin:isProviderConfigured(main) == true,
                name = function(id) return plugin:getProviderDisplayName(id) end,
            })
    elseif name == "privacy" then
        return SetupWizard.probePrivacyF(f)
    elseif name == "icons" then
        -- Configured = the user decided the toggles (any of the three
        -- explicitly present). Registration state rides in the detail.
        local registered = G_reader_settings
            and SetupWizard.findEmojiFallback(G_reader_settings:readSetting("font_ui_fallbacks"))
        local decided = f.enable_emoji_icons ~= nil
            or f.enable_emoji_panel_icons ~= nil
            or f.enable_data_access_indicators ~= nil
        local detail
        if registered then
            detail = f.enable_emoji_icons and _("font registered, icons on")
                or _("font registered")
        elseif decided then
            detail = _("decided without font install")
        end
        return decided, detail
    elseif name == "marks" then
        return SetupWizard.probeMarksF(f)
    elseif name == "gestures" then
        local data = readGesturesData(plugin)
        local count = SetupWizard.scanGestures(data)
        if count > 0 then
            return true, T(_("%1 assigned"), count)
        end
        return false
    end
    return false
end

-- Probe with the dev "pretend unconfigured" flag honored (skip logic only;
-- the inspector shows raw values).
function SetupWizard.probe(plugin, name)
    if feats(plugin)._wizard_pretend_unconfigured then
        return false
    end
    return probeRaw(plugin, name)
end

--- This plugin's version, from its own _meta.lua.
function SetupWizard.thisVersion()
    local ok, meta = pcall(function() return require("koassistant.core.paths").meta() end)
    return ok and type(meta) == "table" and meta.version or "0"
end

--- The face this install gets now (SetupWizard.faceFor over the live state).
function SetupWizard.face(plugin)
    local completed = plugin.settings:readSetting("setup_wizard_completed") and true or false
    local configured = probeRaw(plugin, "provider") and true or false
    local face = SetupWizard.faceFor(completed, configured, feats(plugin)._wizard_version,
        SetupWizard.thisVersion(), SetupWizard.UPDATE_STEPS)
    logger.dbg("KOAssistant wizard: face", face)
    return face
end

--========================================================================--
--  Font install
--========================================================================--

-- Install the bundled font into KOReader's fonts folder and enable it as a UI
-- fallback: ONE installer, run by the wizard's Icons step and by the Emoji
-- Font row in Settings (B397). opts.wizard = the wizard's session (its results
-- line, its restart flag, the glyph test after the restart); opts.done(installed)
-- runs when the flow's last popup closes.
function SetupWizard.installFont(plugin, opts)
    opts = opts or {}
    local ctx = opts.wizard
    local done = opts.done or function() end
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local lfs = require("libs/libkoreader-lfs")
    local util = require("util")
    local ffiutil = require("ffi/util")

    local src = PLUGIN_DIR .. "/fonts/" .. SetupWizard.FONT_FILE
    local dest_dir = fontInstallDir()
    local dest = dest_dir .. "/" .. SetupWizard.FONT_FILE

    if not lfs.attributes(dest, "mode") then
        if not lfs.attributes(src, "mode") then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = _("The bundled emoji font is missing from this build. The wiki's Troubleshooting page has the manual route."),
                dismiss_callback = function() done(false) end,
            })
            return
        end
        util.makePath(dest_dir)
        local err = ffiutil.copyFile(src, dest)
        if err then
            UIManager:show(InfoMessage:new{
                icon = "notice-warning",
                text = T(_("Could not install the font: %1"), tostring(err)),
                dismiss_callback = function() done(false) end,
            })
            return
        end
    end

    -- Register as a UI fallback (KOReader reads this at startup).
    local fallback_added = false
    local list = G_reader_settings:readSetting("font_ui_fallbacks")
    local new_list, reason = SetupWizard.appendFallback(list, dest, SetupWizard.FALLBACK_MAX)
    if new_list then
        G_reader_settings:saveSetting("font_ui_fallbacks", new_list)
        fallback_added = true
    elseif reason == "present" then
        fallback_added = true -- already registered (possibly by the user)
    end

    -- Record what we wrote into KOReader-owned state (precise undo; the
    -- "full reset actually resets" audit reads this).
    local f = feats(plugin)
    f._wizard_font_install = { path = dest, fallback_added = fallback_added }
    logger.info("KOAssistant: emoji font installed at", dest, fallback_added and "and registered" or "(the fallback list is full)")
    if ctx then
        f._wizard_font_pending_confirm = true
    end
    saveFeats(plugin, f)

    if ctx then
        table.insert(ctx.results, _("Emoji font installed (restart pending)"))
        ctx.restart_needed = true
    end

    local function restartThen()
        local UIM = require("ui/uimanager")
        local Device = require("device")
        if not ctx or ctx.single or not Device:canRestart() then
            -- outside the chain, a single topic (Settings > Setup Wizard >
            -- Icons: no chain to resume, the glyph test alone comes at the
            -- next start through resumePending; the sweep of 2026-11-06),
            -- or a device that cannot restart itself (the note "takes effect
            -- on next restart"): KOReader's own ask
            UIM:askForRestart()
            done(true)
            return
        end
        -- In the chain, KOReader's own ask landed on top of the next step,
        -- and Restart now lost the rest of the chain (no stamp written, so
        -- the next start greeted a new install with the update note). Ask
        -- here: Restart now resumes the chain at the icons step after the
        -- restart (the glyph test first); Restart later goes on now, and the
        -- glyph test comes at a later start (resumePending).
        local ConfirmBox = require("ui/widget/confirmbox")
        UIM:show(ConfirmBox:new{
            text = _("Restart KOReader now to load the font? The remaining steps continue after the restart."),
            ok_text = _("Restart now"),
            cancel_text = _("Restart later"),
            ok_callback = function()
                local ff = feats(plugin)
                ff._wizard_resume = { update = ctx.update or false, mark_complete = ctx.mark_complete or false }
                saveFeats(plugin, ff)
                UIM:broadcastEvent(require("ui/event"):new("Restart"))
            end,
            cancel_callback = function() done(true) end,
        })
    end

    if reason == "cap" then
        UIManager:show(InfoMessage:new{
            icon = "notice-warning",
            text = T(_("The font was installed, but KOReader's additional fallback list is full (limit %1). Uncheck one in KOReader Settings > Device > Additional UI fallback fonts, then check Noto Emoji there."), SetupWizard.FALLBACK_MAX),
            dismiss_callback = restartThen,
        })
        return
    end

    local text
    if ctx then
        text = _("Emoji font installed and registered. After the restart, the wizard shows a quick glyph test to confirm it works.")
    else
        text = _("Noto Emoji is installed and enabled as a UI fallback font. Restart KOReader to load it, then tap Emoji Font again to test the icons.")
    end
    UIManager:show(InfoMessage:new{
        text = text,
        dismiss_callback = restartThen,
    })
end

-- The install offer, ONE copy: the wizard's Icons step (opts.wizard = its
-- session), the Emoji Font row in Settings, and the one-time offer when icons
-- are on without a font (opts.intro replaces the first sentence, opts.later
-- names the row for next time).
function SetupWizard.offerFontInstall(plugin, opts)
    opts = opts or {}
    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    local ctx = opts.wizard
    local done = opts.done or function() end
    local intro = opts.intro
        or _("KOReader ships no emoji font, so KOAssistant's menu icons show as empty boxes. Install the bundled Noto Emoji font (about 860 KB) into KOReader now?")
    local tail
    if ctx then
        tail = _("Icons appear in plugin menus, buttons, panels and plain-text windows; the Markdown chat view draws emoji on its own. Requires a KOReader restart; a glyph test follows after it.")
    else
        tail = _("Icons appear in plugin menus, buttons, panels and plain-text windows; the Markdown chat view draws emoji on its own. Requires a KOReader restart; the Emoji Font row then offers a display test.")
    end
    local parts = {}
    if ctx then table.insert(parts, _("ICONS")) end
    table.insert(parts, intro)
    table.insert(parts, tail)
    if opts.later then table.insert(parts, opts.later) end
    local advancing = false
    UIManager:show(ConfirmBox:new{
        text = table.concat(parts, "\n\n"),
        ok_text = _("Install"),
        cancel_text = ctx and _("Skip") or _("Not now"),
        ok_callback = function()
            advancing = true
            SetupWizard.installFont(plugin, { wizard = ctx, done = done })
        end,
        cancel_callback = function()
            if not advancing then
                advancing = true
                done(false)
            end
        end,
    })
end

local function showGlyphTest(plugin, ctx, next_step)
    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    local text = _("EMOJI DISPLAY TEST") .. "\n\n" ..
        _("Do these icons display correctly on your device?") .. "\n\n" ..
        "📄 Document  📝 Notes  📓 Notebook\n" ..
        "🔍 Search  🌐 Web  🎭 Behavior\n" ..
        "📜 History  🔖 Bookmark  📖 Book" .. "\n\n" ..
        _("This font serves the plugin's menus, buttons, panels and plain-text windows; the Markdown chat view draws emoji on its own.") .. "\n\n" ..
        _("If you see blank boxes or question marks, choose \"No\".")

    local advancing = false
    local function clearPending()
        local f = feats(plugin)
        if f._wizard_font_pending_confirm then
            f._wizard_font_pending_confirm = nil
            saveFeats(plugin, f)
        end
    end
    -- Icons already on (the topic menu, the test after a reinstall): the
    -- test confirms them or reinstalls the font; off: it enables them
    local already_on = feats(plugin).enable_emoji_icons == true
    UIManager:show(ConfirmBox:new{
        icon = "notice-info",
        text = text,
        ok_text = already_on and _("Yes, looks good") or _("Yes, enable"),
        cancel_text = already_on and _("No, reinstall the font") or _("No, skip"),
        ok_callback = function()
            advancing = true
            local f = feats(plugin)
            f.enable_emoji_icons = true
            f.enable_emoji_panel_icons = true
            f.enable_data_access_indicators = true
            f._wizard_font_pending_confirm = nil
            saveFeats(plugin, f)
            plugin:updateConfigFromSettings()
            if not already_on then table.insert(ctx.results, _("Emoji icons enabled")) end
            next_step()
        end,
        cancel_callback = function()
            if not advancing then
                advancing = true
                clearPending()
                if already_on then
                    -- the bundled font copied again, then the restart ask
                    os.remove(fontInstallDir() .. "/" .. SetupWizard.FONT_FILE)
                    return SetupWizard.installFont(plugin, { wizard = ctx, done = next_step })
                end
                next_step()
            end
        end,
    })
end

-- The Emoji Font row, Settings → Display Settings → Emoji (B397): the install
-- offer while the font is missing, the restart ask while KOReader has not
-- loaded it, the display test (which turns the icons on) once it has.
function SetupWizard.showFontRow(plugin)
    local state = SetupWizard.readFontState()
    if state == "installed" then
        return showGlyphTest(plugin, { results = {} }, function() end)
    end
    if state == "restart" then
        local UIManager = require("ui/uimanager")
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("Noto Emoji is installed and enabled as a UI fallback font, but KOReader loads fonts at startup. Restart KOReader now?"),
            ok_text = _("Restart"),
            cancel_text = _("Later"),
            ok_callback = function()
                UIManager:askForRestart()
            end,
        })
        return
    end
    SetupWizard.offerFontInstall(plugin, {})
end

-- Once per install: emoji icons are on but no emoji font is there (B397).
-- Runs from ensureInitialized after the first-run wizard and the language
-- prompt; the stamp is written whatever the answer. Returns true when shown.
function SetupWizard.maybeOfferFont(plugin)
    if not plugin.settings:readSetting("setup_wizard_completed") then
        return false
    end
    local f = feats(plugin)
    if f._emoji_font_offered then
        return false
    end
    if not (f.enable_emoji_icons or f.enable_emoji_panel_icons or f.enable_data_access_indicators) then
        return false
    end
    if SetupWizard.readFontState() ~= "missing" then
        return false
    end
    f._emoji_font_offered = true
    saveFeats(plugin, f)
    SetupWizard.offerFontInstall(plugin, {
        intro = _("Emoji icons are on, but KOReader has no emoji font, so they show as empty boxes. Install the bundled Noto Emoji font (about 860 KB) into KOReader now?"),
        later = _("Later: Settings → Display Settings → Emoji → Emoji Font."),
    })
    return true
end

--========================================================================--
--  Steps (each: function(plugin, ctx, next_step); self-skips on its probe
--  unless ctx.force)
--========================================================================--

function SetupWizard.stepWelcome(plugin, ctx, next_step)
    if ctx.single or ctx.update then return next_step() end
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = _("Welcome to KOAssistant!") .. "\n\n" ..
            _("Let's set up five things: how you connect to an AI provider, what the plugin may read, your language and icons, the (KOA) mark on its buttons, and how you open it fast.") .. "\n\n" ..
            _("Every step can be skipped and changed later in Settings. Tap to continue."),
        dismiss_callback = next_step,
    })
end

function SetupWizard.stepRestore(plugin, ctx, next_step)
    -- Only meaningful on a fresh-looking install (no provider configured)
    -- with a backup archive present — the reinstall / new-device story.
    if ctx.update or (not ctx.force and SetupWizard.probe(plugin, "provider")) then
        return next_step()
    end
    local BackupManager = require("koassistant.storage.backup_manager")
    local manager = BackupManager:new()
    local ok, backups = pcall(function() return manager:listBackups() end)
    local real = {}
    if ok then
        for _idx, b in ipairs(backups or {}) do
            if not b.is_restore_point then table.insert(real, b) end
        end
    end
    if #real == 0 then return next_step() end

    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    local advancing = false
    UIManager:show(ConfirmBox:new{
        text = T(_("A KOAssistant backup was found (%1 available)."), #real) .. "\n\n" ..
            _("Restore your previous settings, chats and data instead of setting up from scratch?"),
        ok_text = _("Restore…"),
        cancel_text = _("Set up fresh"),
        ok_callback = function()
            advancing = true
            -- Hand off to the full restore flow (it has its own preview and
            -- option dialogs). The wizard ends here — after a restore the
            -- probes would be stale; re-enter via the topic menu anytime.
            plugin:showRestoreBackupDialog()
        end,
        cancel_callback = function()
            if not advancing then
                advancing = true
                next_step()
            end
        end,
    })
end

--- Connect a provider. A fresh install: the ten common providers, every
--- other built-in one behind "Other providers…", the OpenAI Subscription,
--- Skip for now. Re-run with a provider connected (the topic menu): the
--- connected ones named, "Keep as it is" first, the same list to add another.
function SetupWizard.stepProvider(plugin, ctx, next_step)
    if not ctx.force and SetupWizard.probe(plugin, "provider") then
        return next_step()
    end
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage = require("ui/widget/infomessage")

    local dialog   -- whichever of the step's dialogs is open
    local advancing = false
    local function advanceOnce()
        if advancing then return end
        advancing = true
        next_step()
    end
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end

    -- After a key is saved: offer the inline connectivity test.
    local function offerTest(provider_id, provider_name)
        local followup
        followup = ButtonDialog:new{
            title = T(_("%1 is set up."), provider_name) .. "\n" ..
                _("Test the connection now? (one tiny request)"),
            buttons = {
                {
                    {
                        text = _("Test provider"),
                        callback = function()
                            plugin:testProvider(provider_id)
                        end,
                    },
                    {
                        text = _("Continue"),
                        callback = function()
                            UIManager:close(followup)
                            advanceOnce()
                        end,
                    },
                },
            },
            tap_close_callback = advanceOnce,
        }
        UIManager:show(followup)
    end

    local render  -- the provider list (drawn below); a cancelled key entry returns to it

    local function pickProvider(choice)
        closeDialog()
        if choice.id == "ollama" then
            -- Keyless local default: select it and explain the endpoint.
            local f = feats(plugin)
            f.provider = "ollama"
            f.model = nil
            saveFeats(plugin, f)
            plugin:updateConfigFromSettings()
            table.insert(ctx.results, _("Provider: Ollama (local)"))
            UIManager:show(InfoMessage:new{
                text = _("Ollama selected, no API key needed. It expects a local server at localhost:11434 (other servers are added from the model menu)."),
                dismiss_callback = function() offerTest("ollama", "Ollama") end,
            })
            return
        end
        -- Key entry via the existing dialog: saving the first key also
        -- auto-selects the provider (showApiKeyDialog behavior).
        plugin:showApiKeyDialog(choice.id, choice.name, false, function()
            table.insert(ctx.results, T(_("Provider: %1"), choice.name))
            offerTest(choice.id, choice.name)
        end, nil, render)
    end

    local function keyedNow()
        local f = feats(plugin)
        local has_oauth = type(f.openai_codex_oauth) == "table" and next(f.openai_codex_oauth) ~= nil
        return SetupWizard.keyedProviders(f.api_keys, readFileApiKeys(), has_oauth,
            require("koassistant.api.base").isPlaceholderKey)
    end


    -- Every other built-in provider, by display name, two per row
    local function showOthers()
        closeDialog()
        local common = {}
        for _idx, choice in ipairs(SetupWizard.PROVIDER_CHOICES) do common[choice.id] = true end
        local others = {}
        for _idx, id in ipairs(require("koassistant.request.model_lists").getAllProviders()) do
            if not common[id] and id ~= "openai_codex" then
                others[#others + 1] = { id = id, name = plugin:getProviderDisplayName(id) }
            end
        end
        table.sort(others, function(x, y) return x.name:lower() < y.name:lower() end)
        local rows, row = {}, {}
        for _idx, choice in ipairs(others) do
            local c = choice
            row[#row + 1] = { text = c.name, callback = function() pickProvider(c) end }
            if #row == 2 then rows[#rows + 1] = row; row = {} end
        end
        if #row > 0 then rows[#rows + 1] = row end
        rows[#rows + 1] = {{ text = _("Back"), id = "close", callback = function() closeDialog(); render() end }}
        dialog = ButtonDialog:new{
            title = _("OTHER PROVIDERS") .. "\n" ..
                _("Every other built-in provider. A custom OpenAI-compatible provider is added in Settings > Model."),
            buttons = rows,
            tap_close_callback = function() dialog = nil; render() end,
        }
        UIManager:show(dialog)
    end

    render = function()
        local keyed = keyedNow()
        local connected = #keyed > 0
        local buttons = {}
        if connected then
            buttons[#buttons + 1] = {{ text = _("Keep as it is"), callback = function()
                closeDialog()
                advanceOnce()
            end }}
        end
        local row = {}
        for _idx, choice in ipairs(SetupWizard.PROVIDER_CHOICES) do
            local c = choice
            row[#row + 1] = { text = c.name, callback = function() pickProvider(c) end }
            if #row == 2 then buttons[#buttons + 1] = row; row = {} end
        end
        if #row > 0 then buttons[#buttons + 1] = row end
        buttons[#buttons + 1] = {{ text = _("Other providers…"), callback = showOthers }}
        buttons[#buttons + 1] = {{
            text = _("OpenAI Subscription (no API key)"),
            callback = function()
                closeDialog()
                -- The OAuth connect flow owns the screen from here (its
                -- dialog is modal); the chain goes on once it is done, and
                -- comes back to this list when it is cancelled
                local OAuth = require("koassistant.api.openai_codex_oauth")
                OAuth.startInteractiveConnect(plugin, function(signed_in)
                    if signed_in then
                        table.insert(ctx.results, _("Provider: OpenAI Subscription"))
                        advanceOnce()
                    else
                        SetupWizard.stepProvider(plugin, ctx, next_step)
                    end
                end)
            end,
        }}
        if not connected then
            buttons[#buttons + 1] = {{
                text = _("Skip for now"),
                callback = function()
                    closeDialog()
                    UIManager:show(InfoMessage:new{
                        text = _("No provider configured. Nothing will work until one is: add a key anytime in Settings > API Keys & Auth."),
                        dismiss_callback = advanceOnce,
                    })
                end,
            }}
        end
        local title
        if connected then
            local names = {}
            for _idx, id in ipairs(keyed) do names[#names + 1] = plugin:getProviderDisplayName(id) end
            title = _("CONNECTION") .. "\n" ..
                T(_("Connected: %1."), table.concat(names, ", ")) .. "\n" ..
                _("Keep it as it is, or add another provider: pick one and paste its API key next.")
        else
            title = _("CONNECT A PROVIDER") .. "\n" ..
                _("KOAssistant sends your questions to an AI provider of your choice. Pick yours and paste its API key next. Ollama runs on your own computer and needs no key.")
        end
        dialog = ButtonDialog:new{
            title = title,
            buttons = buttons,
            tap_close_callback = function() dialog = nil; advanceOnce() end,
        }
        UIManager:show(dialog)
    end
    render()
end

function SetupWizard.stepPrivacy(plugin, ctx, next_step)
    if not ctx.force and SetupWizard.probe(plugin, "privacy") then
        return next_step()
    end
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local ConfirmBox = require("ui/widget/confirmbox")

    local dialog
    local advancing = false
    local function advanceOnce()
        if advancing then return end
        advancing = true
        next_step()
    end

    -- The three presets of the question model (ruling 10 of 2026-10-14):
    -- one value for every kind of data; "Allow everything" includes book text
    local function applyPreset(method, label)
        UIManager:close(dialog)
        plugin[method](plugin, nil)
        table.insert(ctx.results, T(_("Privacy: %1"), label))
        advanceOnce()
    end

    -- The update check: this version redid privacy (every switch became
    -- Ask at the upgrade, the books' own values and the trusted list kept);
    -- the step is the notice, and Keep Ask is the first answer
    local head, first_row
    if ctx.update then
        local f = feats(plugin)
        if f._privacy_notice_pending then
            f._privacy_notice_pending = nil
            saveFeats(plugin, f)
        end
        head = _("PRIVACY & DATA") .. "\n" ..
            _("This version changed how privacy works. Every kind of data is now set to Ask: the first action that needs your highlights, notes, notebook, book text, library scan or reading habits asks you first. Your books' own settings and your trusted providers were kept.")
        first_row = {
            { text = _("Keep Default (Ask)"), callback = function()
                UIManager:close(dialog)
                -- a decision: the topic menu reads it as set (the probe)
                local ff = feats(plugin)
                ff._privacy_decided = true
                saveFeats(plugin, ff)
                table.insert(ctx.results, _("Privacy: Default (Ask)"))
                advanceOnce()
            end },
        }
    else
        head = _("PRIVACY & DATA") .. "\n" ..
            _("What may KOAssistant send to your AI provider? Your highlights, notes, notebook, book text, library scan and reading habits each have one setting: Ask, Allow or Never.")
        first_row = {
            { text = _("Default (Ask)"), callback = function() applyPreset("applyPrivacyPresetDefault", _("Default (Ask)")) end },
        }
    end
    dialog = ButtonDialog:new{
        title = head .. "\n" ..
            _("With Ask, the first action that needs a kind of data asks you, and your answer can be kept for the book. A book can have its own settings, and a book's Never always wins.") .. "\n" ..
            _("Spoiler protection is separate and on by default."),
        buttons = {
            first_row,
            {
                { text = _("Allow everything"), callback = function() applyPreset("applyPrivacyPresetFull", _("Allow everything")) end },
                { text = _("Block everything"), callback = function() applyPreset("applyPrivacyPresetMinimal", _("Block everything")) end },
            },
            {
                {
                    text = _("Decide later"),
                    callback = function()
                        UIManager:close(dialog)
                        advanceOnce()
                    end,
                },
            },
        },
        tap_close_callback = advanceOnce,
    }
    UIManager:show(dialog)
end

function SetupWizard.stepLanguage(plugin, ctx, next_step)
    if ctx.force then
        -- Topic-menu entry: go straight to the picker (the confirm flow
        -- self-skips when a language is already set).
        return plugin:showWizardLanguagePicker(next_step)
    end
    if SetupWizard.probe(plugin, "language") then
        return next_step()
    end
    -- Reuse the existing, working step (auto-detect + confirm-or-choose).
    plugin:showSetupStep2Language(next_step)
end

function SetupWizard.stepIcons(plugin, ctx, next_step)
    local f = feats(plugin)
    if f._wizard_font_pending_confirm then
        -- Post-restart continuation of an earlier install.
        return showGlyphTest(plugin, ctx, next_step)
    end
    if ctx.update then
        -- The update check (the maintainer, 2026-10-19: "verify emoji if
        -- enabled, ask to enable if not, check and install font"): by the
        -- state of the icons and the font. The start-time offer (maybeOfferFont)
        -- is this step's job now, so its stamp is written here.
        local UIManager = require("ui/uimanager")
        local ConfirmBox = require("ui/widget/confirmbox")
        if not f._emoji_font_offered then
            f._emoji_font_offered = true
            saveFeats(plugin, f)
        end
        local icons_on = (f.enable_emoji_icons or f.enable_emoji_panel_icons or f.enable_data_access_indicators) and true or false
        local font_state = SetupWizard.readFontState()
        local plan = SetupWizard.iconsPlan(icons_on, font_state)
        if plan == "test" then
            -- icons on and the font installed: nothing to check (the
            -- maintainer, 2026-10-19: no display test in the update check)
            logger.dbg("KOAssistant wizard: icons on and the font installed, nothing to do")
            return next_step()
        elseif plan == "install" then
            return SetupWizard.offerFontInstall(plugin, { wizard = ctx, done = next_step,
                intro = _("Emoji icons are on, but KOReader has no emoji font, so they show as empty boxes. Install the bundled Noto Emoji font (about 860 KB) into KOReader now?") })
        end
        local advancing = false
        local function advanceOnce()
            if advancing then return end
            advancing = true
            next_step()
        end
        if plan == "restart" then
            UIManager:show(ConfirmBox:new{
                text = _("ICONS") .. "\n\n" .. _("The emoji font is installed, but KOReader loads fonts at startup. Restart KOReader now? The icons show after it."),
                ok_text = _("Restart"),
                cancel_text = _("Later"),
                ok_callback = function()
                    advancing = true
                    ctx.restart_needed = true
                    UIManager:askForRestart()
                end,
                cancel_callback = advanceOnce,
            })
            return
        end
        -- "offer": the icons are off
        UIManager:show(ConfirmBox:new{
            text = _("ICONS") .. "\n\n" .. _("Emoji icons are off. Turn them on? They mark the plugin's menus, buttons and panels (never the chat view), and the emoji font installs with them when KOReader has none."),
            ok_text = _("Turn on"),
            cancel_text = _("Keep off"),
            ok_callback = function()
                advancing = true
                if font_state == "installed" then
                    local ff = feats(plugin)
                    ff.enable_emoji_icons = true
                    ff.enable_emoji_panel_icons = true
                    ff.enable_data_access_indicators = true
                    saveFeats(plugin, ff)
                    plugin:updateConfigFromSettings()
                    table.insert(ctx.results, _("Emoji icons enabled"))
                    next_step()
                else
                    -- the glyph test after the restart turns them on
                    SetupWizard.offerFontInstall(plugin, { wizard = ctx, done = next_step })
                end
            end,
            cancel_callback = advanceOnce,
        })
        return
    end
    if not ctx.force and SetupWizard.probe(plugin, "icons") then
        return next_step()
    end
    local registered = G_reader_settings
        and SetupWizard.findEmojiFallback(G_reader_settings:readSetting("font_ui_fallbacks"))
    if registered then
        return showGlyphTest(plugin, ctx, next_step)
    end
    SetupWizard.offerFontInstall(plugin, { wizard = ctx, done = next_step })
end


-- The two panels, each in its own mode (the Quick Actions panel is a reader
-- gesture, the Quick Settings panel a file-browser one)
-- The (KOA) mark on KOAssistant's buttons (B511; the maintainer 2026-10-19:
-- "useful if you have many plugins that add buttons"): one answer writes the
-- three per-surface keys. A CONFIGURE step: the welcome chain, the topic
-- menu, and the update check once for a reader who never touched the boxes.
function SetupWizard.stepMarks(plugin, ctx, next_step)
    if not ctx.force and SetupWizard.probe(plugin, "marks") then
        return next_step()
    end
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Constants = require("koassistant.core.constants")

    local dialog
    local advancing = false
    local function advanceOnce()
        if advancing then return end
        advancing = true
        next_step()
    end
    local function pick(shown)
        UIManager:close(dialog)
        local f = feats(plugin)
        for _surface, key in pairs(Constants.KOA_SUFFIX_KEYS) do f[key] = shown end
        saveFeats(plugin, f)
        logger.dbg("KOAssistant wizard: button marks", shown and "shown" or "hidden")
        table.insert(ctx.results, shown and _("Button marks: (KOA) shown") or _("Button marks: (KOA) hidden"))
        advanceOnce()
    end
    local now = select(2, SetupWizard.probeMarksF(feats(plugin)))
    dialog = ButtonDialog:new{
        title = _("BUTTON MARKS") .. "\n" ..
            _("KOAssistant adds buttons to the highlight menu, the dictionary popup and the file browser's long-press menu, beside KOReader's own. A (KOA) mark at the end of their names tells them apart, which helps when several plugins add buttons there.") .. "\n" ..
            _("For example: Explain (KOA)") .. "\n" ..
            T(_("The mark is %1 now."), now),
        buttons = {
            {
                { text = _("Show the mark"), callback = function() pick(true) end },
                { text = _("Hide the mark"), callback = function() pick(false) end },
            },
            {
                { text = _("Decide later"), callback = function()
                    UIManager:close(dialog)
                    advanceOnce()
                end },
            },
        },
        tap_close_callback = advanceOnce,
    }
    UIManager:show(dialog)
end

local PANELS = {
    { id = "koassistant_quick_actions", label = _("Quick Actions"), section_key = "gesture_reader" },
    { id = "koassistant_ai_settings", label = _("Quick Settings"), section_key = "gesture_fm" },
}

--- Open it fast (B489): one row per panel with its gesture or "not set", a
--- tap opening the gesture picker (every KOReader gesture, a taken one
--- replaceable after a confirm); on a fresh install with the default corner
--- free in both modes, one button binds both to it. The update check shows
--- the same rows with "Keep as they are".
function SetupWizard.stepGestures(plugin, ctx, next_step)
    if not ctx.force and SetupWizard.probe(plugin, "gestures") then
        return next_step()
    end
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local GesturePicker = require("koassistant.ui.gesture_picker")

    local data = GesturePicker.access(plugin)
    if not GesturePicker.ready(data) then
        -- gestures.lua not initialized yet (Gestures plugin never ran?) —
        -- don't invent its file shape; point at the manual route.
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = _("GESTURES") .. "\n\n" ..
                _("KOAssistant's panels can be bound to gestures in KOReader Settings (gear icon) > Taps and gestures. KOReader's gesture data isn't ready yet, so set them up there, or from Settings > Gestures later."),
            dismiss_callback = next_step,
        })
        return
    end

    local changed = {}
    local advancing = false
    local function finish()
        if advancing then return end
        advancing = true
        if #changed > 0 then
            table.insert(ctx.results, T(_("Gestures: %1"), table.concat(changed, "; ")))
        end
        next_step()
    end
    local function note(panel, slot, how)
        table.insert(changed, T(_("%1 on %2"), panel.label, GesturePicker.slotLabel(slot)))
        if how == "restart" then ctx.restart_needed = true end
    end

    local dialog
    local function render()
        if dialog then UIManager:close(dialog); dialog = nil end
        data = GesturePicker.access(plugin)
        local buttons = {}
        local default_free = GesturePicker.plan((data.gesture_reader or {}).tap_right_bottom_corner, PANELS[1].id) == "free"
            and GesturePicker.plan((data.gesture_fm or {}).tap_right_bottom_corner, PANELS[2].id) == "free"
        if default_free then
            buttons[#buttons + 1] = {{ text = _("Assign both to tap bottom-right corner"), callback = function()
                for _idx, panel in ipairs(PANELS) do
                    note(panel, "tap_right_bottom_corner",
                        GesturePicker.assign(plugin, panel.section_key, "tap_right_bottom_corner", panel.id, { wizard = ctx }))
                end
                render()
            end }}
        end
        for _idx, p in ipairs(PANELS) do
            local panel = p
            buttons[#buttons + 1] = {{
                text = T(_("%1: %2"), panel.label, GesturePicker.bindingsText(data, panel.id) or _("not set")),
                callback = function()
                    if dialog then UIManager:close(dialog); dialog = nil end
                    GesturePicker.show({
                        plugin = plugin, action_id = panel.id, action_label = panel.label,
                        section_key = panel.section_key, wizard = ctx,
                        on_done = function(slot, how)
                            if slot then note(panel, slot, how) end
                            render()
                        end,
                        on_cancel = render,
                    })
                end,
            }}
        end
        buttons[#buttons + 1] = {{ text = ctx.update and _("Keep as they are") or _("Done"), id = "close", callback = function()
            if dialog then UIManager:close(dialog); dialog = nil end
            finish()
        end }}
        local lines = { _("OPEN IT FAST") }
        if ctx.update then
            table.insert(lines, _("Your two panels have these gestures. Keep them, or tap one to change it: every KOReader gesture is on offer, and a gesture in use can be replaced."))
        else
            table.insert(lines, _("KOAssistant has two panels: Quick Actions while reading (book actions, artifacts and utilities) and Quick Settings in the file browser (provider, model, behavior and more). Give each a gesture; a gesture in use can be replaced."))
        end
        dialog = ButtonDialog:new{
            title = table.concat(lines, "\n"),
            buttons = buttons,
            tap_close_callback = function() dialog = nil; finish() end,
        }
        UIManager:show(dialog)
    end
    render()
end

function SetupWizard.stepFinish(plugin, ctx, next_step)
    if ctx.single then
        if next_step then next_step() end
        return
    end
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")

    local lines = { ctx.update and _("UPDATE CHECK COMPLETE") or _("SETUP COMPLETE") }
    if #ctx.results > 0 then
        table.insert(lines, "")
        for _idx, r in ipairs(ctx.results) do
            table.insert(lines, "• " .. r)
        end
    end
    table.insert(lines, "")
    table.insert(lines, _("You'll also find KOAssistant in the highlight menu, the dictionary popup, the file browser long-press, and the main menu."))
    if ctx.restart_needed then
        table.insert(lines, "")
        table.insert(lines, _("Restart KOReader to finish (font and gesture changes need it)."))
    end
    table.insert(lines, "")
    table.insert(lines, _("Settings → Setup Wizard runs any part of this again."))

    -- The stamps: this version's check is done (either face), and the
    -- completion flag the release passes
    local f = feats(plugin)
    f._wizard_version = SetupWizard.baseVersion(SetupWizard.thisVersion())
    saveFeats(plugin, f)
    if ctx.mark_complete then
        plugin.settings:saveSetting("setup_wizard_completed", true)
        plugin.settings:flush()
    end

    local dialog
    dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        buttons = {
            {
                {
                    text = _("Open a chat"),
                    callback = function()
                        UIManager:close(dialog)
                        plugin:onKOAssistantGeneralChat()
                    end,
                },
                {
                    text = _("Done"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

--========================================================================--
--  Runners
--========================================================================--

local CHAIN = {
    { key = "welcome",  fn = function(...) return SetupWizard.stepWelcome(...) end },
    { key = "restore",  fn = function(...) return SetupWizard.stepRestore(...) end },
    { key = "provider", fn = function(...) return SetupWizard.stepProvider(...) end },
    { key = "privacy",  fn = function(...) return SetupWizard.stepPrivacy(...) end },
    { key = "language", fn = function(...) return SetupWizard.stepLanguage(...) end },
    { key = "icons",    fn = function(...) return SetupWizard.stepIcons(...) end },
    { key = "marks",    fn = function(...) return SetupWizard.stepMarks(...) end },
    { key = "gestures", fn = function(...) return SetupWizard.stepGestures(...) end },
    { key = "finish",   fn = function(...) return SetupWizard.stepFinish(...) end },
}

local PROBED = { provider = true, privacy = true, language = true, icons = true, marks = true, gestures = true }

-- opts: force (run every step), mark_complete (write the completion flag at
-- the finish step: the first interaction passes this; dev runs never do),
-- update (the update check: only this version's listed steps, forced, plus
-- whatever is not set up yet; SetupWizard.shouldRun).
function SetupWizard.runChain(plugin, opts)
    opts = opts or {}
    local only
    if opts.update then
        only = {}
        local keys = SetupWizard.UPDATE_STEPS[SetupWizard.baseVersion(SetupWizard.thisVersion())] or {}
        for _idx, k in ipairs(keys) do only[k] = true end
    end
    local ctx = {
        force = opts.force or false,
        update = opts.update or false,
        mark_complete = opts.mark_complete or false,
        results = {},
        restart_needed = false,
    }
    local i = 0
    local started = not opts.from   -- opts.from = the key of the step to resume at
    local function advance()
        i = i + 1
        local step = CHAIN[i]
        if not step then return end
        if not started then
            if step.key ~= opts.from then return advance() end
            started = true
        end
        local configured = PROBED[step.key] and SetupWizard.probe(plugin, step.key) or false
        local run, forced = SetupWizard.shouldRun(step.key, { update = ctx.update, only = only, force = opts.force }, configured)
        logger.dbg("KOAssistant wizard: step", step.key, run and (forced and "run, forced" or "run") or "skip")
        if not run then return advance() end
        ctx.force = forced
        local ok, err = pcall(step.fn, plugin, ctx, advance)
        if not ok then
            logger.warn("KOAssistant wizard: step", step.key, "failed:", err)
            advance()
        end
    end
    advance()
end

--- At start, before the face (main.lua checkSetupWizard): a chain cut by
--- the font install's Restart now resumes at the icons step (the glyph test,
--- then the rest); a font installed with Restart later gets its glyph test
--- alone once KOReader has loaded the font. True when it took the start.
function SetupWizard.resumePending(plugin)
    local UIManager = require("ui/uimanager")
    local f = feats(plugin)
    local resume = f._wizard_resume
    if type(resume) == "table" then
        f._wizard_resume = nil
        saveFeats(plugin, f)
        logger.dbg("KOAssistant wizard: resuming the chain at icons", resume.update and "(update)" or "(fresh)")
        UIManager:nextTick(function()
            SetupWizard.runChain(plugin, { update = resume.update == true,
                mark_complete = resume.mark_complete == true, from = "icons" })
        end)
        return true
    end
    if f._wizard_font_pending_confirm and SetupWizard.readFontState() == "installed" then
        logger.dbg("KOAssistant wizard: the glyph test after the font's restart")
        UIManager:nextTick(function()
            SetupWizard.stepIcons(plugin, { force = true, single = true, results = {}, restart_needed = false },
                function() end)
        end)
        return true
    end
    return false
end

-- The completer surface: per-topic state, each row runs one step forced.
function SetupWizard.showTopicMenu(plugin)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")

    local topics = {
        { key = "provider", label = _("Connection"), step = SetupWizard.stepProvider },
        { key = "privacy",  label = _("Privacy"),    step = SetupWizard.stepPrivacy },
        { key = "language", label = _("Language"),   step = SetupWizard.stepLanguage },
        { key = "icons",    label = _("Icons"),      step = SetupWizard.stepIcons },
        { key = "marks",    label = _("Button marks"), step = SetupWizard.stepMarks },
        { key = "gestures", label = _("Gestures"),   step = SetupWizard.stepGestures },
    }

    local dialog
    local buttons = {}
    for _idx, topic in ipairs(topics) do
        local configured, detail = probeRaw(plugin, topic.key)
        local suffix
        if configured then
            suffix = detail and T(_("✓ %1"), detail) or _("✓ configured")
        else
            suffix = _("not set")
        end
        table.insert(buttons, {
            {
                text = topic.label .. ": " .. suffix,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    local ctx = { force = true, single = true, results = {}, restart_needed = false }
                    topic.step(plugin, ctx, function()
                        -- Reopen with fresh states so the ✓ marks update.
                        SetupWizard.showTopicMenu(plugin)
                    end)
                end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Run everything"),
            callback = function()
                UIManager:close(dialog)
                SetupWizard.runChain(plugin, { force = true })
            end,
        },
    })
    table.insert(buttons, {{ text = _("Close"), id = "close", callback = function() UIManager:close(dialog) end }})
    dialog = ButtonDialog:new{
        title = _("Setup Wizard") .. "\n" .. _("Each topic shows whether it is set up. Tap one to set it up again."),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- The update check's opening note (the second face): what this version
--- changed, Check now or Later. Both write the stamp (once per release,
--- never nagging) and clear the privacy notice, which the note carries.
function SetupWizard.runUpdate(plugin)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage = require("ui/widget/infomessage")
    local version = SetupWizard.baseVersion(SetupWizard.thisVersion())
    local NOTES = {
        privacy = _("Privacy: every kind of data is now set to Ask, so the first action that needs it asks you first."),
        icons = _("Emoji icons: a check that they show, and the emoji font installed when KOReader has none."),
        gestures = _("The panels' gestures: every KOReader gesture on offer, a gesture in use replaceable."),
    }
    local lines = {
        T(_("KOAssistant was updated to v%1."), version),
        _("A few things are new or changed since your last setup. Check them now?"),
    }
    for _idx, key in ipairs(SetupWizard.UPDATE_STEPS[version] or {}) do
        if NOTES[key] then table.insert(lines, "• " .. NOTES[key]) end
    end
    local function stamp()
        local f = feats(plugin)
        f._wizard_version = version
        f._privacy_notice_pending = nil
        saveFeats(plugin, f)
        logger.dbg("KOAssistant wizard: update check stamped", version)
    end
    local dialog
    local acted = false
    dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        buttons = {
            {
                { text = _("Check now"), callback = function()
                    acted = true
                    UIManager:close(dialog)
                    stamp()
                    SetupWizard.runChain(plugin, { update = true, mark_complete = true })
                end },
                { text = _("Later"), callback = function()
                    acted = true
                    UIManager:close(dialog)
                    stamp()
                    UIManager:show(InfoMessage:new{ text = _("Settings → Setup Wizard runs any of these steps any time."), timeout = 3 })
                end },
            },
        },
        tap_close_callback = function() if not acted then stamp() end end,
    }
    UIManager:show(dialog)
end

--========================================================================--
--  Dev menu (Settings ▸ Advanced, debug-gated: the probes and the stamps)
--========================================================================--

function SetupWizard.showDevMenu(plugin)
    local UIManager = require("ui/uimanager")
    local ButtonDialog = require("ui/widget/buttondialog")
    local InfoMessage = require("ui/widget/infomessage")

    local f = feats(plugin)
    local pretend = f._wizard_pretend_unconfigured == true

    local dialog
    local buttons = {
        {
            {
                text = _("Run setup chain"),
                callback = function()
                    UIManager:close(dialog)
                    SetupWizard.runChain(plugin)
                end,
            },
            {
                text = _("Run all steps (force)"),
                callback = function()
                    UIManager:close(dialog)
                    SetupWizard.runChain(plugin, { force = true })
                end,
            },
        },
        {
            {
                text = _("Topic menu (completer)"),
                callback = function()
                    UIManager:close(dialog)
                    SetupWizard.showTopicMenu(plugin)
                end,
            },
        },
        {
            {
                text = _("Probe inspector"),
                callback = function()
                    UIManager:close(dialog)
                    local lines = { _("Wizard probes (raw state):"), "" }
                    for _idx, name in ipairs({ "provider", "privacy", "language", "icons", "marks", "gestures" }) do
                        local configured, detail = probeRaw(plugin, name)
                        local state = configured and "✓" or "✗"
                        table.insert(lines, string.format("%s %s%s", state, name,
                            detail and (": " .. detail) or ""))
                    end
                    local ff = feats(plugin)
                    table.insert(lines, "")
                    table.insert(lines, "setup_wizard_completed: "
                        .. tostring(plugin.settings:readSetting("setup_wizard_completed") or false))
                    table.insert(lines, "_wizard_version: " .. tostring(ff._wizard_version) .. " (this: "
                        .. SetupWizard.baseVersion(SetupWizard.thisVersion()) .. ")")
                    table.insert(lines, "font pending confirm: "
                        .. tostring(ff._wizard_font_pending_confirm or false))
                    table.insert(lines, "pretend unconfigured: "
                        .. tostring(ff._wizard_pretend_unconfigured or false))
                    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
                end,
            },
        },
        {
            {
                text = pretend and _("Pretend unconfigured: ON")
                    or _("Pretend unconfigured: off"),
                callback = function()
                    UIManager:close(dialog)
                    local ff = feats(plugin)
                    ff._wizard_pretend_unconfigured = not pretend or nil
                    saveFeats(plugin, ff)
                    SetupWizard.showDevMenu(plugin)
                end,
            },
            {
                text = _("Clear completion flag"),
                callback = function()
                    UIManager:close(dialog)
                    plugin.settings:delSetting("setup_wizard_completed")
                    plugin.settings:flush()
                    UIManager:show(InfoMessage:new{
                        text = _("Completion flag cleared: with no provider set up, the welcome chain fires on the next first interaction."),
                        timeout = 3,
                    })
                end,
            },
        },
        {
            {
                text = _("Clear the version stamp (the update check fires again)"),
                callback = function()
                    UIManager:close(dialog)
                    local ff = feats(plugin)
                    ff._wizard_version = nil
                    saveFeats(plugin, ff)
                    UIManager:show(InfoMessage:new{
                        text = T(_("Stamp cleared: face now \"%1\"."), SetupWizard.face(plugin)),
                        timeout = 3,
                    })
                end,
            },
            {
                text = _("Run the update check"),
                callback = function()
                    UIManager:close(dialog)
                    SetupWizard.runUpdate(plugin)
                end,
            },
        },
    }
    dialog = ButtonDialog:new{
        title = _("Setup Wizard (dev tools)") .. "\n" ..
            T(_("Face now: %1"), SetupWizard.face(plugin)),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

return SetupWizard
