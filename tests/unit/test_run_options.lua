-- Run options (koassistant_run_options.lua, B345, docs/run_options_plan.md): the
-- hold menu's "Run once with:" buttons per action and state, the dispatch-scoped
-- model stash (B295: a model written for one action never rides into the next),
-- the trust gate's mirror of the run option, and the saved-chat capture.
--
-- Run: lua tests/unit/test_run_options.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant_api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")
local RunOptions = require("koassistant_run_options")
local TestRunner = require("test_runner"):new()

local TIERS = { fast = "claude-haiku-4-5" }

local function state(over)
    local st = {
        base = { provider = "anthropic", model = "claude-sonnet-5" },
        tier_base = "anthropic",
        quick = { receptive = true, on = false },
        reasoning = { pinned = false, mode = "on", can_disable = true },
        web = { pinned = false, on = false, capable = true },
        configured = function() return true end,
        resolveTier = function(p, tier)
            if TIERS[tier] then return p, TIERS[tier] end
            return nil
        end,
        emoji = false,
    }
    for k, v in pairs(over or {}) do st[k] = v end
    return st
end

local function labels(buttons)
    local out = {}
    for _idx, b in ipairs(buttons) do out[#out + 1] = b.label end
    return table.concat(out, " | ")
end

local PROSE = { id = "explain", accept_quick_answer = true }

-- ---------------------------------------------------------------- buttons

TestRunner:test("defaults: a receptive prose action gets one button per pair", function()
    local b = RunOptions.buttons(RunOptions.DEFAULTS, PROSE, state())
    TestRunner:assertEqual(labels(b), "Quick answer | claude-haiku-4-5 | No reasoning | With web search",
        "labels")
    TestRunner:assertEqual(b[1].variant.quick, true, "quick on")
    TestRunner:assertEqual(b[3].variant.reasoning, "off", "reasoning off")
    TestRunner:assertEqual(b[4].variant.web, true, "web on")
end)

TestRunner:test("icons: the facet's own icon on every button when emoji icons are on", function()
    local b = RunOptions.buttons(RunOptions.DEFAULTS, PROSE, state({ emoji = true }))
    TestRunner:assertEqual(labels(b),
        "\u{26A1} Quick answer | \u{1F916} claude-haiku-4-5 | \u{1F9E0} No reasoning | \u{1F310} With web search",
        "labels")
end)

TestRunner:test("the Fast button carries the resolved provider and model, never the tier", function()
    local b = RunOptions.buttons(RunOptions.DEFAULTS, PROSE, state())
    TestRunner:assertEqual(b[2].variant.provider, "anthropic", "provider")
    TestRunner:assertEqual(b[2].variant.model, "claude-haiku-4-5", "model")
    TestRunner:assertEqual(b[2].variant.tier, nil, "no tier on the request")
end)

TestRunner:test("each pair shows only the half that changes something; no reasoning-on button", function()
    local st = state({
        quick = { receptive = true, on = true },
        reasoning = { pinned = false, mode = "off", can_disable = true },
        web = { pinned = false, on = true, capable = true },
    })
    local b = RunOptions.buttons(RunOptions.DEFAULTS, PROSE, st)
    TestRunner:assertEqual(labels(b), "Without Quick | claude-haiku-4-5 | Without web search", "labels")
    TestRunner:assertEqual(b[1].variant.quick, false, "quick off")
end)

TestRunner:test("the chip rule: what the action sets itself gets no button", function()
    local st = state({
        reasoning = { pinned = true, mode = "on", can_disable = true },
        web = { pinned = true, on = false, capable = true },
        quick = { receptive = false, on = false },
    })
    local b = RunOptions.buttons(RunOptions.DEFAULTS, { id = "eli5" }, st)
    TestRunner:assertEqual(labels(b), "claude-haiku-4-5", "model only")
end)

TestRunner:test("no reasoning button when the model cannot turn it off; no web when it cannot search", function()
    local st = state({
        reasoning = { pinned = false, mode = "on", can_disable = false },
        web = { pinned = false, on = false, capable = false },
    })
    local b = RunOptions.buttons(RunOptions.DEFAULTS, PROSE, st)
    TestRunner:assertEqual(labels(b), "Quick answer | claude-haiku-4-5", "labels")
end)

TestRunner:test("artifact actions take model buttons only", function()
    for _idx, a in ipairs({
        { id = "summary", use_response_caching = true, accept_quick_answer = true },
        { id = "xray", cache_as_xray = true },
        { id = "quiz", interactive_quiz = true },
        { id = "recap", update_prompt = "…" },
    }) do
        local b = RunOptions.buttons(RunOptions.DEFAULTS, a, state())
        TestRunner:assertEqual(labels(b), "claude-haiku-4-5", a.id)
        TestRunner:assertTrue(RunOptions.isModelOnly(a), a.id .. " is model-only")
    end
    TestRunner:assertFalse(RunOptions.isModelOnly(PROSE), "prose is not")
end)

TestRunner:test("Fast equal to what the action runs on, a missing tier, a keyless provider: hidden", function()
    local b = RunOptions.buttons(RunOptions.DEFAULTS, PROSE,
        state({ base = { provider = "anthropic", model = "claude-haiku-4-5" } }))
    TestRunner:assertFalse(labels(b):find("claude-haiku", 1, true) ~= nil, "Fast equals the base")
    b = RunOptions.buttons(RunOptions.DEFAULTS, PROSE, state({ resolveTier = function() return nil end }))
    TestRunner:assertEqual(labels(b), "Quick answer | No reasoning | With web search", "no fast placement")
    b = RunOptions.buttons(RunOptions.DEFAULTS, PROSE, state({
        resolveTier = function(_p, tier) if tier == "fast" then return "groq", "llama-fast" end end,
        configured = function(p) return p ~= "groq" end,
    }))
    TestRunner:assertFalse(labels(b):find("llama", 1, true) ~= nil, "keyless global tier pin")
end)

-- ---------------------------------------------------------------- recent picks

TestRunner:test("recent picks fill the model spots ahead of Fast: at most three, each model once", function()
    local recent = {
        { provider = "openai", model = "gpt-6-luna" },
        { provider = "anthropic", model = "claude-sonnet-5" },   -- what a tap uses: skipped
        { provider = "anthropic", model = "claude-haiku-4-5" },  -- the Fast model: shown once
        { provider = "groq", model = "llama-x" },                -- keyless: skipped
    }
    local st = state({ configured = function(p) return p ~= "groq" end })
    local b = RunOptions.buttons(RunOptions.list({ run_recent_models = recent }), PROSE, st)
    TestRunner:assertEqual(labels(b), "Quick answer | gpt-6-luna | claude-haiku-4-5 | No reasoning | With web search",
        "recents first, Fast deduped, base and keyless skipped")
    recent = {
        { provider = "openai", model = "a" }, { provider = "openai", model = "b" },
        { provider = "openai", model = "c" }, { provider = "openai", model = "d" },
    }
    b = RunOptions.buttons(RunOptions.list({ run_recent_models = recent }), { id = "xray", cache_as_xray = true }, state())
    TestRunner:assertEqual(labels(b), "a | b | c", "three spots; Fast waits for a free one")
end)

TestRunner:test("list(): the defaults with recent picks ahead of Fast; bad entries skipped", function()
    local l = RunOptions.list({})
    TestRunner:assertEqual(#l, #RunOptions.DEFAULTS, "no recents: the defaults")
    l = RunOptions.list({ run_recent_models = { { provider = "openai", model = "gpt-6-luna" }, "junk", { provider = 1 } } })
    TestRunner:assertEqual(l[3].model, "gpt-6-luna", "recent before Fast")
    TestRunner:assertEqual(l[4].tier, "fast", "then Fast")
    TestRunner:assertEqual(#l, #RunOptions.DEFAULTS + 1, "junk dropped")
end)

TestRunner:test("addRecent: a new pick goes first, a known one keeps its place, the oldest drops", function()
    local l = RunOptions.addRecent({}, "openai", "a")
    TestRunner:assertEqual(l[1].model, "a", "first pick")
    l = RunOptions.addRecent(l, "openai", "b")
    TestRunner:assertEqual(l[1].model .. l[2].model, "ba", "newest first")
    TestRunner:assertEqual(RunOptions.addRecent(l, "openai", "a"), nil, "reuse changes nothing")
    for _idx, m in ipairs({ "c", "d", "e", "f" }) do l = RunOptions.addRecent(l, "openai", m) end
    TestRunner:assertEqual(#l, RunOptions.RECENT_KEEP, "capped")
    TestRunner:assertEqual(l[#l].model, "b", "oldest dropped")
    TestRunner:assertEqual(RunOptions.addRecent(l, nil, "x"), nil, "needs a provider")
end)

TestRunner:test("rememberPick saves the pick to the settings; a known pick writes nothing", function()
    local saved, flushed = nil, 0
    local features = {}
    local plugin = { settings = {
        readSetting = function(_self, key) if key == "features" then return features end end,
        saveSetting = function(_self, key, value) if key == "features" then saved = value end end,
        flush = function() flushed = flushed + 1 end,
    } }
    RunOptions.rememberPick(plugin, "openai", "gpt-6-luna")
    TestRunner:assertEqual(saved and saved.run_recent_models[1].model, "gpt-6-luna", "saved")
    TestRunner:assertEqual(flushed, 1, "flushed")
    RunOptions.rememberPick(plugin, "openai", "gpt-6-luna")
    TestRunner:assertEqual(flushed, 1, "no second write")
end)

-- ---------------------------------------------------------------- live state

-- stateFor runs inside the hold menu's pcall: a wrong call there would only
-- hide the buttons, so drive it against the real resolvers here.
local function fakePlugin(features)
    return {
        settings = { readSetting = function(_self, key) if key == "features" then return features end end },
        getCurrentProvider = function() return features.provider end,
        getCurrentModel = function() return features.model end,
        hasAnyRealApiKey = function() return true end,
        isProviderConfigured = function(_self, p) return p == features.provider end,
    }
end

TestRunner:test("stateFor: live state for an unpinned prose action yields tier buttons on the active provider", function()
    local ModelLists = require("koassistant_model_lists")
    local fast = ModelLists.resolveTierModel("anthropic", "fast")
    TestRunner:assertTrue(fast ~= nil, "anthropic has a fast tier")
    local plugin = fakePlugin({ provider = "anthropic", model = ModelLists.anthropic[1] })
    local st = RunOptions.stateFor(plugin, PROSE, { surface = "highlight" })
    TestRunner:assertEqual(st.base.provider, "anthropic", "base provider")
    local b = RunOptions.buttons(RunOptions.list({}), PROSE, st)
    local found = false
    for _idx, x in ipairs(b) do
        if x.variant.model == fast then found = true end
    end
    TestRunner:assertTrue(found or ModelLists.anthropic[1] == fast, "Fast button targets the fast tier")
end)

TestRunner:test("stateFor: a pinned action's base is its pin; the input dialog's chips are the session", function()
    local plugin = fakePlugin({ provider = "anthropic", model = "claude-sonnet-5" })
    local st = RunOptions.stateFor(plugin, { id = "x", provider = "openai", model = "gpt-5.5" },
        { surface = "input", session = { quick = false, web = true } })
    TestRunner:assertEqual(st.base.provider, "openai", "pin provider")
    TestRunner:assertEqual(st.base.model, "gpt-5.5", "pin model")
    TestRunner:assertEqual(st.tier_base, "openai", "tiers resolve on the pin's provider")
    TestRunner:assertTrue(st.web.on, "session web chip")
end)

-- ---------------------------------------------------------------- stash

-- createTempConfig's copy: two levels deep, nested per-provider tables shared
local function copy2(src)
    local t = {}
    for k, v in pairs(src) do
        if type(v) ~= "table" then
            t[k] = v
        else
            t[k] = {}
            for k2, v2 in pairs(v) do t[k][k2] = v2 end
        end
    end
    return t
end

TestRunner:test("B295: a pinned action's model does not ride into the next action", function()
    local viewer = {
        provider = "openai", model = "gpt-pin",
        provider_settings = { openai = { model = "gpt-pin" }, anthropic = { model = "claude-sonnet-5" } },
        features = {
            _model_stash = { orig = { provider = "anthropic", model = "claude-sonnet-5" }, ps = { openai = false } },
            _quick_reply_orig = { provider = "openai" },
            _run_model = { provider = "openai", model = "gpt-pin" },
            _run_reasoning = "off",
        },
    }
    local inherited_stash = viewer.features._model_stash
    local temp = copy2(viewer)
    RunOptions.beginDispatch(temp, viewer, { id = "dictionary" })
    TestRunner:assertEqual(temp.provider, "anthropic", "provider restored")
    TestRunner:assertEqual(temp.model, "claude-sonnet-5", "model restored")
    TestRunner:assertEqual(temp.provider_settings.openai.model, nil, "pin bucket restored")
    TestRunner:assertEqual(viewer.provider_settings.openai.model, "gpt-pin", "source untouched")
    TestRunner:assertTrue(temp.features._model_stash ~= inherited_stash, "fresh stash")
    TestRunner:assertEqual(inherited_stash.ps.openai, false, "inherited stash not mutated")
    TestRunner:assertEqual(temp.features._model_stash.orig.provider, "anthropic", "new orig")
    TestRunner:assertEqual(temp.features._quick_reply_orig, nil, "old reply baseline dropped")
    TestRunner:assertEqual(temp.features._run_model, nil, "old run model dropped")
    TestRunner:assertEqual(temp.features._run_reasoning, nil, "old run reasoning dropped")
end)

TestRunner:test("no inherited stash: createTempConfig's pin write is undone for the caller to re-apply", function()
    local source = {
        provider = "anthropic", model = "claude-sonnet-5",
        provider_settings = { anthropic = { model = "claude-sonnet-5" } },
        features = {},
    }
    local temp = copy2(source)
    temp.provider = "openai"                                -- createTempConfig's pin
    temp.provider_settings.openai = { model = "gpt-pin" }
    RunOptions.beginDispatch(temp, source, { id = "x", provider = "openai", model = "gpt-pin" })
    TestRunner:assertEqual(temp.provider, "anthropic", "provider back to the source")
    TestRunner:assertEqual(temp.provider_settings.openai, nil, "pin bucket back to the source")
    TestRunner:assertEqual(temp.features._model_stash.orig.model, "claude-sonnet-5", "orig recorded")
end)

TestRunner:test("stashBucket keeps the first value of a dispatch", function()
    local cfg = { provider_settings = { anthropic = { model = "a1" } }, features = {} }
    RunOptions.beginDispatch(cfg, { provider_settings = cfg.provider_settings }, nil)
    RunOptions.stashBucket(cfg, "anthropic")
    cfg.provider_settings.anthropic = { model = "a2" }
    RunOptions.stashBucket(cfg, "anthropic")
    RunOptions.stashBucket(cfg, "gemini")
    TestRunner:assertEqual(cfg.features._model_stash.ps.anthropic, "a1", "first value")
    TestRunner:assertEqual(cfg.features._model_stash.ps.gemini, false, "absent bucket = false")
end)

TestRunner:test("a tier hint's model is undone at the next dispatch (the old tier stash's job)", function()
    local base = {
        provider = "anthropic", model = "claude-sonnet-5",
        provider_settings = { anthropic = { model = "claude-sonnet-5" } },
        features = {},
    }
    -- Dispatch 1 (quick_define: fast tier)
    local d1 = copy2(base)
    RunOptions.beginDispatch(d1, base, { id = "quick_define" })
    RunOptions.stashBucket(d1, "anthropic")
    d1.model = "claude-haiku-4-5"
    d1.provider_settings.anthropic = { model = "claude-haiku-4-5" }
    -- Dispatch 2 from the viewer's config (action swap to an unhinted action)
    local d2 = copy2(d1)
    RunOptions.beginDispatch(d2, d1, { id = "dictionary" })
    TestRunner:assertEqual(d2.model, "claude-sonnet-5", "model restored")
    TestRunner:assertEqual(d2.provider_settings.anthropic.model, "claude-sonnet-5", "bucket restored")
end)

-- ---------------------------------------------------------------- trust gate + saved state

local Dialogs = require("koassistant_dialogs")

TestRunner:test("trust gate: a run option's picked model beats the action's pin", function()
    local p = Dialogs.effectiveDispatchProvider(
        { _run_variant = { provider = "openai", model = "gpt-5.5" } },
        { id = "translate", provider = "deepseek" }, "deepseek")
    TestRunner:assertEqual(p, "openai", "run option provider")
end)

TestRunner:test("trust gate: a run option's Quick part replaces the chip, accept-gated, never on artifacts", function()
    local preset = { quick_preset_model_mode = "model", quick_preset_provider = "gemini",
        quick_preset_model = "gemini-fast" }
    local f = { _run_variant = { quick = false }, _quick_answer_active = true }
    for k, v in pairs(preset) do f[k] = v end
    TestRunner:assertEqual(Dialogs.effectiveDispatchProvider(f, { accept_quick_answer = true }, "anthropic"),
        "anthropic", "Without Quick suppresses the preset model")
    f = { _run_variant = { quick = true } }
    for k, v in pairs(preset) do f[k] = v end
    TestRunner:assertEqual(Dialogs.effectiveDispatchProvider(f, { accept_quick_answer = true }, "anthropic"),
        "gemini", "Quick answer applies the preset model")
    TestRunner:assertEqual(Dialogs.effectiveDispatchProvider(f,
        { accept_quick_answer = true, use_response_caching = true }, "anthropic"),
        "anthropic", "artifact action ignores the Quick part")
end)

-- ---------------------------------------------------------------- the bake

local function bake(features, action, provider, model)
    local cfg = {
        provider = provider or "anthropic", model = model or "claude-sonnet-5",
        provider_settings = {}, features = features,
    }
    local trust = Dialogs.effectiveDispatchProvider(features, action, cfg.provider)
    Dialogs._buildUnifiedRequestConfig(cfg, nil, action, nil)
    return cfg, trust
end

TestRunner:test("bake: a picked model beats the action's pin, and the trust gate agrees", function()
    local f = { _run_variant = { provider = "openai", model = "gpt-5.5" } }
    local cfg, trust = bake(f, { id = "translate", provider = "deepseek" }, "deepseek", nil)
    TestRunner:assertEqual(cfg.provider, "openai", "provider")
    TestRunner:assertEqual(cfg.model, "gpt-5.5", "model")
    TestRunner:assertEqual(trust, cfg.provider, "trust gate = dispatch")
    TestRunner:assertEqual(f._run_variant, nil, "consumed")
    TestRunner:assertEqual(f._run_model.provider, "openai", "recorded for the saved chat")
end)

TestRunner:test("bake: the trust gate matches the dispatch provider for Quick parts", function()
    local preset = { quick_preset_model_mode = "model", quick_preset_provider = "gemini",
        quick_preset_model = "gemini-fast" }
    local cases = {
        { f = { _run_variant = { quick = true } }, a = { id = "explain", accept_quick_answer = true } },
        { f = { _run_variant = { quick = false }, _quick_answer_active = true },
          a = { id = "explain", accept_quick_answer = true } },
        { f = { _run_variant = { quick = true } }, a = { id = "summary", use_response_caching = true } },
        { f = { _run_variant = { quick = true, provider = "openai", model = "gpt-5.5" } },
          a = { id = "explain", accept_quick_answer = true } },
    }
    for i, c in ipairs(cases) do
        for k, v in pairs(preset) do c.f[k] = v end
        local cfg, trust = bake(c.f, c.a)
        TestRunner:assertEqual(trust, cfg.provider, "case " .. i)
    end
end)

TestRunner:test("bake: a web pick holds under Quick and marks the facet touched", function()
    local f = { _run_variant = { web = true }, _quick_answer_active = true }
    local cfg = bake(f, { id = "explain", accept_quick_answer = true })
    TestRunner:assertEqual(cfg.enable_web_search, true, "web stays on")
    TestRunner:assertEqual(f._session_web_touched, true, "replies keep it")
end)

TestRunner:test("bake: an artifact action takes the model only", function()
    local f = { _run_variant = { provider = "openai", model = "gpt-5.5", quick = true, web = true, reasoning = "on" } }
    local cfg = bake(f, { id = "summary", use_response_caching = true })
    TestRunner:assertEqual(cfg.provider, "openai", "model applies")
    TestRunner:assertEqual(f._session_quick_answer, nil, "no Quick")
    TestRunner:assertEqual(f._run_reasoning, nil, "no reasoning")
    TestRunner:assertFalse(cfg.enable_web_search == true, "no web")
end)

TestRunner:test("bake: an action's own reasoning wins over the run option's", function()
    local f = { _run_variant = { reasoning = "on" } }
    local cfg = bake(f, { id = "eli5", reasoning_config = "off" }, "anthropic", "claude-sonnet-5")
    TestRunner:assertEqual(cfg.api_params._reasoning.mode, "off", "action's off stands")
    TestRunner:assertEqual(f._run_reasoning, nil, "not recorded for the chat")
end)

TestRunner:test("replies in a Quick chat stay on the run option's model", function()
    local f = { _session_quick_answer = true, quick_preset_model_mode = "model",
        quick_preset_provider = "gemini", quick_preset_model = "gemini-fast",
        _run_model = { provider = "openai", model = "gpt-5.5" }, _run_reasoning = "on" }
    local cfg = { provider = "openai", model = "gpt-5.5", provider_settings = {},
        api_params = {}, features = f }
    Dialogs.applyQuickReplyOverrides(cfg, nil)
    TestRunner:assertEqual(cfg.provider, "openai", "not the preset's provider")
    TestRunner:assertEqual(cfg.model, "gpt-5.5", "not the preset's model")
end)

-- ---------------------------------------------------------------- attachments

TestRunner:test("attachments: a notebook reaches only a provider allowed to have it", function()
    local A = require("koassistant_attachments")
    local saved = A.notebookOverrideFor
    local override = nil
    A.notebookOverrideFor = function() return override end
    local ok, err = pcall(function()
        local list = { { type = "notebook", path = "/b.epub" }, { type = "note", text = "x" } }
        local f = { enable_notebook_sharing = false, trusted_providers = { "ollama" } }
        local out = A.forProvider(list, f, "openai")
        TestRunner:assertEqual(#out, 1, "notebook left out for an untrusted provider")
        TestRunner:assertEqual(out[1].type, "note", "the rest stays")
        TestRunner:assertEqual(#A.forProvider(list, f, "ollama"), 2, "trusted keeps it")
        override = false
        TestRunner:assertEqual(#A.forProvider(list, f, "ollama"), 1, "the book's deny beats trusted")
        override = true
        TestRunner:assertEqual(#A.forProvider(list, f, "openai"), 2, "the book's allow")
    end)
    A.notebookOverrideFor = saved
    if not ok then error(err, 0) end
end)

TestRunner:test("saved chat state keeps a run option's model and reasoning; a chat pick wins", function()
    local CHM = require("koassistant_chat_history_manager")
    local cs = CHM.captureControlState({ features = {
        _run_model = { provider = "openai", model = "gpt-5.5" }, _run_reasoning = "off" } })
    TestRunner:assertEqual(cs.model.provider, "openai", "model")
    TestRunner:assertEqual(cs.reasoning.force, "off", "reasoning")
    cs = CHM.captureControlState({ features = {
        _run_model = { provider = "openai", model = "gpt-5.5" },
        _session_model = { provider = "anthropic", model = "claude-opus-5-5" } } })
    TestRunner:assertEqual(cs.model.provider, "anthropic", "a later chat pick wins")
end)

return TestRunner:summary()
