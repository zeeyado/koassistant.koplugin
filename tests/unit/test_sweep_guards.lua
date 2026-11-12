-- Source guards for the 2026-11-06 sweep's main.lua fixes (batch A, items
-- A10 to A13 in docs/sweep_2026-11-06.md): the dictionary popup's local
-- actions and the bypass run on a scrubbed copy of the configuration, never
-- the shared table; the book-level direct run scrubs its copy; the Analyze
-- Notes popup acts on its own book; Add custom model goes through
-- switchModel and the removals guard the provider.
--
-- Run: lua tests/unit/test_sweep_guards.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
    return plugin_dir
end
local plugin_dir = setupPaths()
require("mock_koreader")
local TestRunner = require("test_runner"):new()

local function read(rel)
    local f = assert(io.open(plugin_dir .. "/" .. rel, "r"))
    local s = f:read("*a")
    f:close()
    return s
end
local function fnBody(src, name)
    local a = src:find("function AskGPT:" .. name .. "%(")
    assert(a, name)
    local b = src:find("\nfunction AskGPT:", a + 10) or #src
    return src:sub(a, b)
end
local main = read("main.lua")

print("Running: test_sweep_guards")
print("")
print("  [the dictionary popup and the bypass run local actions on a scrubbed copy]")

TestRunner:test("executeDictAction's local branch hands a scrubbed copy to executeDirectAction", function()
    local body = fnBody(main, "executeDictAction")
    TestRunner:assertTrue(body:find("self:_scrubContextFeatures(local_config.features)", 1, true) ~= nil, "the copy is scrubbed")
    TestRunner:assertTrue(body:find("Dialogs.executeDirectAction(self.ui, action, word, local_config, self,", 1, true) ~= nil, "the copy is passed")
    TestRunner:assertTrue(body:find("configuration.features._source_widget = dict_popup", 1, true) == nil, "nothing written on the shared table")
end)

TestRunner:test("the bypass's local branch does the same", function()
    local body = fnBody(main, "syncDictionaryBypass")
    TestRunner:assertTrue(body:find("self_ref:_scrubContextFeatures(local_config.features)", 1, true) ~= nil, "scrubbed")
    TestRunner:assertTrue(body:find("Dialogs.executeDirectAction(self_ref.ui, bypass_action, clean_word, local_config, self_ref,", 1, true) ~= nil, "the copy is passed")
end)

TestRunner:test("the scrub forgets the popup reference", function()
    local body = fnBody(main, "_scrubContextFeatures")
    TestRunner:assertTrue(body:find("features._source_widget = nil", 1, true) ~= nil)
end)

print("")
print("  [the book-level direct run and the Analyze Notes popup]")

TestRunner:test("_executeBookLevelActionDirect scrubs its copy before marking the book context", function()
    local body = fnBody(main, "_executeBookLevelActionDirect")
    local s = body:find("self:_scrubContextFeatures(config_copy.features)", 1, true)
    local b = body:find("config_copy.features.is_book_context = true", 1, true)
    TestRunner:assertTrue(s ~= nil and b ~= nil and s < b, "scrub first, then is_book_context")
end)

TestRunner:test("the Analyze Notes popup's View and requirement checks name its own book", function()
    local body = fnBody(main, "_showAnalyzeNotesScopePopup")
    TestRunner:assertTrue(body:find("viewCachedAction(action, action_id, cached_entry,\n          { file = target_file", 1, true) ~= nil, "View passes the book")
    local n = select(2, body:gsub("_checkRequirements%(action, target_file,", ""))
    TestRunner:assertEqual(n, 3)
    TestRunner:assertTrue(body:find("_checkRequirements(action, nil,", 1, true) == nil, "no open-book judgement left")
end)

print("")
print("  [custom models in another provider's panel]")

TestRunner:test("Add custom model goes through switchModel; the removals guard the provider", function()
    TestRunner:assertTrue(main:find("self_ref:switchModel(provider, new_model, provider_display_name)", 1, true) ~= nil, "the Add callback switches")
    local body = fnBody(main, "removeCustomModel")
    TestRunner:assertTrue(body:find("if self:getCurrentProvider() == provider and self:getCurrentModel() == model then", 1, true) ~= nil, "remove guards the provider")
    TestRunner:assertTrue(main:find("local was_custom = self_ref:getCurrentProvider() == provider\n            and self_ref:isCustomModel(provider, current_model)", 1, true) ~= nil, "Clear all guards the provider")
end)

print("")
print("  [the sweep's dialogs fixes: batch B]")

local dialogs = read("koassistant/ui/dialogs.lua")

TestRunner:test("the checkpoint size safeguard reads the build flag where it lives (message_data)", function()
    TestRunner:assertTrue(dialogs:find("local xb_build = message_data._ladder_build\n", 1, true) ~= nil, "message_data")
    TestRunner:assertTrue(dialogs:find("local xb_build = config.features and config.features._ladder_build", 1, true) == nil,
        "never the features copy the request's creation cleared")
end)

TestRunner:test("a rotated Save Chat or New Tag dialog becomes the one its buttons act on", function()
    TestRunner:assertTrue(dialogs:find("save_dialog = new_dialog  -- the buttons close and read THIS dialog now\n        UIManager:show(new_dialog)", 1, true) ~= nil, "Save Chat")
    TestRunner:assertTrue(dialogs:find("tag_input = new_tag_dialog  -- the buttons act on THIS dialog now\n                    UIManager:show(new_tag_dialog)", 1, true) ~= nil, "New Tag")
end)

TestRunner:test("a library chat tags under its own store", function()
    TestRunner:assertTrue(dialogs:find('elseif tf and tf.is_library_context then\n                    effective_path = "__LIBRARY_CHATS__"', 1, true) ~= nil)
end)

TestRunner:test("the AI Wiki from a selection asks for the text around it before any request; a Cancel drops the entry's keys", function()
    local a = dialogs:find("local function askWikiAccess(run)", 1, true)
    TestRunner:assertTrue(a ~= nil, "the asker")
    local b = dialogs:find("\n        end\n", a, true)
    local fn = dialogs:sub(a, b + 12)
    -- both runs go through it
    local branch = dialogs:sub(a, dialogs:find("\n    end\n", a, true))
    local n = select(2, branch:gsub("askWikiAccess%(function%(%)", ""))
    TestRunner:assertEqual(n, 2, "the fresh run and the regenerate")
    TestRunner:assertEqual(select(2, branch:gsub("executeActionForResult%(action, highlighted_text", "")), 2, "the only two calls")
    local Dialogs = require("koassistant.ui.dialogs")
    local calls = {}
    local env = setmetatable({
        require = function(name)
            if name == "koassistant.ui.data_access" then
                return { withAccess = function(plugin, action, opts, run) calls[#calls + 1] = { opts = opts, run = run } end }
            end
            return require(name)
        end,
        effectiveDispatchProvider = Dialogs.effectiveDispatchProvider,
        dropDispatchTransients = Dialogs.dropDispatchTransients,
        _ = function(x) return x end,
        plugin = {}, ui = {}, document_path = "/books/a.epub",
        action = { id = "wiki", text = "AI Wiki" },
        configuration = { provider = "anthropic", features = { _run_variant = { web = false } } },
    }, { __index = _G })
    local chunk = assert(load(fn .. "\nreturn askWikiAccess", "askWikiAccess", "t", env))
    local ask = chunk()
    local ran = 0
    ask(function() ran = ran + 1 end)
    TestRunner:assertEqual(ran, 1, "no selection window: nothing to ask, the run goes")
    TestRunner:assertEqual(#calls, 0)
    env.configuration.features._selection_context_window = { before = "a b.", after = "c d." }
    ask(function() ran = ran + 1 end)
    TestRunner:assertEqual(ran, 1, "a window: the question first, nothing sent")
    TestRunner:assertEqual(#calls, 1)
    local o = calls[1].opts
    TestRunner:assertEqual(o.kinds[1].kind, "nearby_text")
    TestRunner:assertEqual(o.kinds[1].required, false, "optional: Continue without is offered")
    TestRunner:assertEqual(o.path, "/books/a.epub")
    TestRunner:assertEqual(o.provider, "anthropic")
    TestRunner:assertEqual(o.action_name, "AI Wiki")
    o.on_cancel()
    TestRunner:assertEqual(env.configuration.features._selection_context_window, nil, "a Cancel drops the window")
    TestRunner:assertEqual(env.configuration.features._run_variant, nil, "and the run option")
end)

TestRunner:test("an artifact chat's run option survives the question's re-entry", function()
    local a = dialogs:find("local function launchArtifactChat(", 1, true)
    local body = dialogs:sub(a, dialogs:find("\nlocal function ", a + 10, true) or #dialogs)
    local take = body:find("local run_variant = configuration.features._run_variant", 1, true)
    local bake = body:find("buildUnifiedRequestConfig(configuration, domain_context, nil, plugin)", 1, true)
    TestRunner:assertTrue(take ~= nil and bake ~= nil and take < bake, "taken before the bake consumes it")
    local n = select(2, body:gsub("configuration%.features%._run_variant = run_variant\n%s*launchArtifactChat%(", ""))
    TestRunner:assertEqual(n, 2, "put back before both re-entries (the notebook's and the stamps' question)")
end)

print("")
print("  [the sweep's main.lua fixes: batch B]")

TestRunner:test("Generate (complete) from a closed book's dialog runs to 100% with no page of the open book", function()
    TestRunner:assertTrue(dialogs:find("local function runAction(update_opts)", 1, true) ~= nil, "runAction takes the popup's choice")
    TestRunner:assertTrue(dialogs:find("configuration.features._complete_analysis =\n                    (update_opts and update_opts.complete_analysis) or nil", 1, true) ~= nil,
        "and sets the flag just in time")
    -- the override block, cut from the request and run on both shapes
    local block = dialogs:match("(local complete_analysis = config%.features and config%.features%._complete_analysis\n.-\n    end\n)")
    TestRunner:assertTrue(block ~= nil, "the override block")
    local run = assert(load("local config, ui, is_file_browser_target, message_data = ...\n" .. block .. "\nreturn message_data", "override"))
    -- a closed book beside an open one: 100%, and not the open book's page count
    local cf = { _complete_analysis = true }
    local md = run({ features = cf }, { document = { file = "/open.epub", info = { number_of_pages = 300 } } }, true, {})
    TestRunner:assertEqual(md.progress_decimal, "1.0")
    TestRunner:assertEqual(md.reading_progress, "100%")
    TestRunner:assertEqual(md.progress_page, nil, "no page of another book")
    TestRunner:assertEqual(cf._complete_analysis, nil, "consumed")
    -- the file browser, no document at all
    md = run({ features = { _complete_analysis = true } }, nil, true, {})
    TestRunner:assertEqual(md.progress_decimal, "1.0")
    -- the open book: its own page count
    md = run({ features = { _complete_analysis = true } }, { document = { file = "/open.epub", info = { number_of_pages = 300 } } }, false, {})
    TestRunner:assertEqual(md.progress_page, 300)
    -- nothing set: nothing overridden
    md = run({ features = {} }, { document = { file = "/open.epub", info = { number_of_pages = 300 } } }, false, { progress_decimal = "0.4" })
    TestRunner:assertEqual(md.progress_decimal, "0.4")
end)

TestRunner:test("the first key switches the provider only for a reader who has none in use", function()
    local fn = main:match("(local function firstKeySwitches%(current, provider, current_configured, other_keys%)\n.-\nend\n)")
    TestRunner:assertTrue(fn ~= nil, "the rule")
    local switches = assert(load(fn .. "\nreturn firstKeySwitches", "firstKeySwitches"))()
    TestRunner:assertTrue(switches("anthropic", "gemini", false, false), "a fresh install: the first key is the provider")
    TestRunner:assertFalse(switches("openai_codex", "gemini", true, false), "a Subscription user adding a key keeps the Subscription")
    TestRunner:assertFalse(switches("ollama", "gemini", true, false), "an Ollama user the same")
    TestRunner:assertFalse(switches("anthropic", "anthropic", true, false), "re-saving the current provider's own key")
    TestRunner:assertFalse(switches("anthropic", "gemini", false, true), "another key exists already")
    local body = fnBody(main, "showApiKeyDialog")
    TestRunner:assertTrue(body:find("firstKeySwitches(current, provider,\n                self_ref:isProviderConfigured(current), hasAnyApiKeys(f.api_keys, provider))", 1, true) ~= nil, "the Save asks the rule")
    TestRunner:assertTrue(body:find("f.model = self_ref:getEffectiveDefaultModel(provider)", 1, true) ~= nil, "the switch picks the new provider's default model")
    TestRunner:assertTrue(body:find("f.model = nil", 1, true) == nil)
end)

TestRunner:test("an X-Ray lookup from a card or the bypass is about the open book", function()
    local body = fnBody(main, "_openXrayEntityDirect")
    TestRunner:assertTrue(body:find("document_path = (opts and opts.document_path)\n      or (self.ui and self.ui.document and self.ui.document.file),", 1, true) ~= nil, "the card's opener")
    local bypass = fnBody(main, "syncDictionaryBypass")
    TestRunner:assertTrue(bypass:find("document_path = lookup_book_override\n            or (self_ref.ui.document and self_ref.ui.document.file),", 1, true) ~= nil, "the bypass's local branch")
end)

TestRunner:test("no surface reads the provider as features.provider or anthropic (the main provider is one read)", function()
    local offenders = {}
    for _idx, rel in ipairs({ "main.lua", "koassistant/ui/settings_schema.lua" }) do
        local n = 0
        for line in read(rel):gmatch("[^\n]+") do
            n = n + 1
            local prefix = line:match("([%w_]+)%.provider or \"anthropic\"")
            if prefix == "features" or prefix == "f" then
                offenders[#offenders + 1] = rel .. ":" .. n
            end
        end
    end
    TestRunner:assertEqual(table.concat(offenders, ", "), "", "every read goes through getCurrentProvider or ConfigHelper.mainProvider")
    TestRunner:assertTrue(main:find("local provider = provider_arg or self:getCurrentProvider()", 1, true) ~= nil, "the reasoning popup")
    TestRunner:assertTrue(fnBody(main, "onKOAssistantAISettings"):find("local provider = self:getCurrentProvider()", 1, true) ~= nil, "Quick Settings")
end)

TestRunner:test("a restore reloads this instance's settings in place, the object and the features table kept", function()
    local fn = fnBody(main, "_reloadSettingsFromDisk")
    local disk = { ["/settings.lua"] = {
        features = { enable_streaming = false, restored = true },
        highlight_menu_actions = { "restored" },
    } }
    local function copy(t)
        local o = {}
        for k, v in pairs(t) do o[k] = type(v) == "table" and copy(v) or v end
        return o
    end
    local env = setmetatable({
        LuaSettings = { open = function(_, path) return { data = copy(disk[path]) } end },
        AskGPT = {},
    }, { __index = _G })
    assert(load(fn, "reload", "t", env))()
    local features = { enable_streaming = true, _spoiler_free_active = true }
    local data = { features = features, highlight_menu_actions = { "old" }, stale_only = 1 }
    local settings = { data = data }
    local synced = 0
    local plugin = { _settings_path = "/settings.lua", settings = settings,
        updateConfigFromSettings = function(self) synced = synced + 1 end }
    env.AskGPT._reloadSettingsFromDisk(plugin)
    TestRunner:assertTrue(plugin.settings == settings, "the settings object is the same one")
    TestRunner:assertTrue(settings.data == data, "its data table too")
    TestRunner:assertTrue(data.features == features, "the features table keeps its reference (the merge is updateConfigFromSettings's)")
    TestRunner:assertEqual(data.highlight_menu_actions[1], "restored", "a top-level key replaced")
    TestRunner:assertEqual(data.stale_only, nil, "a key the restore does not have is gone")
    TestRunner:assertEqual(synced, 1, "the features merge and the configuration sync ran")
    -- first thing on a successful restore, before the two other stores are
    -- reloaded (audit 2026-11-12) and before the v1 chats import
    local body = fnBody(main, "_performRestore")
    local ok_at = body:find("if result.success then", 1, true)
    local reload_at = body:find("self:_reloadSettingsFromDisk()", 1, true)
    local groups_at = body:find('require("koassistant.books.book_groups").reload()', 1, true)
    local v1_at = body:find("if result.v1_chats_restored then", 1, true)
    TestRunner:assertTrue(ok_at and reload_at and groups_at and v1_at
        and ok_at < reload_at and reload_at < groups_at and groups_at < v1_at,
        "run first thing on a successful restore")
end)

print("")
print("  [Test provider: a refused forced call grants no tools]")

TestRunner:test("the Forced tool use step clears caps.tools on every failure return", function()
    local a = main:find('label = _("Forced tool use (book-tools search)")', 1, true)
    TestRunner:assertTrue(a ~= nil, "the step")
    local body = main:sub(a, main:find("end },", a, true))
    local cleared = body:find("caps.tools = nil", 1, true)
    local first_false = body:find("return false", 1, true)
    TestRunner:assertTrue(cleared ~= nil and first_false ~= nil and cleared < first_false, "cleared before the failure returns")
end)

-- Audit 2026-11-12 (reviewer D2's storage findings), at the source where no
-- harness drives them
TestRunner:test("after a restore the stores that held the old state read the disk again", function()
    local src = read("main.lua")
    local a = src:find("self:_reloadSettingsFromDisk()", 1, true)
    TestRunner:assertTrue(a ~= nil, "the restore's success branch")
    local branch = src:sub(a, a + 1200)
    TestRunner:assertTrue(branch:find('require("koassistant.books.book_groups").reload()', 1, true) ~= nil,
        "the book groups' session handle is dropped (it wrote the old groups back at the next group change)")
    TestRunner:assertTrue(branch:find("self.action_service.actions_cache = nil", 1, true) ~= nil,
        "the action list's cache is dropped (a menu build pruned the restored custom actions)")
    local groups = read("koassistant/books/book_groups.lua")
    TestRunner:assertTrue(groups:find("function BookGroups.reload()", 1, true) ~= nil, "BookGroups.reload exists")
end)

TestRunner:test("Restore defaults on behaviors keeps the deleted ids reserved", function()
    local src = read("koassistant/ui/behavior_manager.lua")
    local a = src:find('_("Restore defaults")', 1, true)
    TestRunner:assertTrue(a ~= nil, "the row")
    local row = src:sub(a, a + 900)
    local reserve = row:find("self_ref:reserveIds()", 1, true)
    local save = row:find("self_ref:saveCustomBehaviors({})", 1, true)
    TestRunner:assertTrue(reserve ~= nil and save ~= nil and reserve < save, "ids reserved before the list is emptied")
end)

TestRunner:test("a failed restore names its reason without a source position or the chats' text", function()
    local src = read("koassistant/storage/backup_manager.lua")
    for line in src:gmatch("[^\n]+") do
        if line:find('error(e or', 1, true) or line:find('error(err_w or', 1, true) then
            TestRunner:assertTrue(line:find(", 0) end", 1, true) ~= nil,
                "error level 0, so the reader's message carries no file and line: " .. line:match("^%s*(.-)%s*$"))
        end
    end
    TestRunner:assertTrue(src:find('"Failed to decode chat JSON: " .. tostring(all_chats)', 1, true) == nil,
        "the decoder's message (it quotes the chats) is not passed on")
    TestRunner:assertTrue(src:find('"Failed to decode chat JSON (" .. tostring(#content) .. " bytes)"', 1, true) ~= nil,
        "only the size is")
end)

return TestRunner:summary()
