-- Unit tests for koassistant/storage/migrations.lua — the one-time settings upgrade chain
-- (extracted verbatim from AskGPT:initSettings, 2026-08-10; release_prep_v0.21 C0).
--
-- The chain had ZERO coverage while guarding every user's upgrade path. These are
-- fixture tests: synthetic on-disk feature tables (a real v0.20.0 shape, a fresh
-- install seed, deliberate-choice shapes) run through Migrations.run, asserting
-- key outcomes AND idempotence (a second run must change nothing — the class of
-- bug where a migration re-fires per launch and re-materializes keys).
--
-- The v0.20.0 stamp set below is verified against tag 9a303f1 (grep for
-- `features.* = true` stamps in that revision's main.lua).
-- No API calls.
--
-- Run: lua tests/run_tests.lua --unit   (or: lua tests/unit/test_migrations.lua)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant/api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")

    return plugin_dir, tests_dir
end

setupPaths()

require("mock_koreader")

local Migrations = require("koassistant.storage.migrations")
local Constants = require("koassistant.core.constants")

local TestRunner = {
    passed = 0,
    failed = 0,
    current_suite = "",
}

function TestRunner:suite(name)
    self.current_suite = name
    print(string.format("\n  [%s]", name))
end

function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("    \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("    \226\156\151 %s", name))
        print(string.format("      Error: %s", tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", msg or "Assertion failed",
            tostring(expected), tostring(actual)))
    end
end

function TestRunner:assertTrue(value, msg)
    if not value then
        error(string.format("%s: expected true", msg or "Assertion failed"))
    end
end

function TestRunner:summary()
    print("")
    print(string.rep("-", 50))
    local total = self.passed + self.failed
    if self.failed == 0 then
        print(string.format("  All %d tests passed!", total))
    else
        print(string.format("  %d/%d tests passed, %d failed", self.passed, total, self.failed))
    end
    return self.failed == 0
end

-- Deep compare (tables by structure, everything else by equality).
local function deepEqual(a, b, path)
    path = path or "root"
    if type(a) ~= type(b) then
        return false, path .. ": type " .. type(a) .. " != " .. type(b)
    end
    if type(a) ~= "table" then
        if a ~= b then
            return false, path .. ": " .. tostring(a) .. " != " .. tostring(b)
        end
        return true
    end
    for k, v in pairs(a) do
        local ok, why = deepEqual(v, b[k], path .. "." .. tostring(k))
        if not ok then return false, why end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false, path .. "." .. tostring(k) .. ": missing in first"
        end
    end
    return true
end

local function assertDeepEqual(actual, expected, msg)
    local ok, why = deepEqual(actual, expected)
    if not ok then
        error((msg or "deep-equal failed") .. " (" .. why .. ")")
    end
end

local function deepCopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepCopy(v) end
    return out
end

local CANONICAL_CHIPS = { "domain", "web_search", "book_tools", "quick", "scope", "attach", "spoiler" }

-- A v0.20.0 install's features table (stamps verified against tag 9a303f1) plus
-- era-plausible user state that the post-0.20.0 migrations must transform, and an
-- interim-build key (xray_auto_update: the old auto-X-Ray master shipped and was
-- replaced between releases — the chain must still honor any pre-migration disk).
local function v020Fixture()
    return {
        -- stamps a v0.20.0 install already carries
        behavior_migrated = true,
        languages_migrated = true,
        _reasoning_v2_migrated = true,
        _quiz_chapter_level_reset = true,
        _language_prompt_shown = true,
        ui_language = "auto",
        interaction_languages = { "English" },
        additional_languages = {},
        -- v0.20.0-era user state the newer migrations transform
        show_spoiler_toggle = true,
        enable_tool_workflows = false,
        web_search_max_uses = 2,
        dictionary_context_mode = "sentence",
        dictionary_context_chars = 300,
        dictionary_bypass_action = "dictionary",
        -- interim dev builds: old auto-X-Ray master ON (per-book boolean opt-ins era)
        xray_auto_update = true,
        -- ordinary settings that must ride through untouched
        translation_language = "German",
        enable_book_text_extraction = true,
    }
end

print("")
print(string.rep("=", 50))
print("  Unit Tests: Settings Migrations (upgrade chain)")
print(string.rep("=", 50))

--------------------------------------------------------------------------------
TestRunner:suite("v0.20.0 upgrade fixture")

TestRunner:test("chain reports changes and stamps every post-0.20.0 guard", function()
    local f = v020Fixture()
    local needs_save = Migrations.run(f)
    TestRunner:assertTrue(needs_save, "needs_save must be true on a v0.20.0 table")
    for _idx, stamp in ipairs({
        "_xray_auto_v2_migrated", "_tools_posture_migrated",
        "_tools_binary_migrated",
        "_session_chips_migrated", "_session_chips_scope_v2",
        "_session_chips_attach_v1", "_session_chips_quick_v1",
        "_web_search_effort_migrated", "_dict_bypass_default_migrated",
        "_highlight_context_migrated", "_session_chips_registry_v1",
        "_privacy_ask_migrated",
    }) do
        TestRunner:assertEqual(f[stamp], true, stamp)
    end
end)

TestRunner:test("the Ask reset (B395): a switch that was on becomes Ask, position and per-book values stay, the notice is owed", function()
    local f = v020Fixture()
    f.enable_highlights_sharing = true
    f.enable_notebook_sharing = false
    f.enable_basic_stats = false
    f.trusted_providers = { "ollama" }
    Migrations.run(f)
    TestRunner:assertEqual(f.enable_book_text_extraction, nil, "text: on becomes Ask")
    TestRunner:assertEqual(f.enable_highlights_sharing, nil, "highlights: on becomes Ask")
    TestRunner:assertEqual(f.enable_notebook_sharing, nil, "notebook: off reads as Ask already")
    TestRunner:assertEqual(f.enable_basic_stats, false, "reading position keeps its own two values")
    TestRunner:assertEqual(f.trusted_providers[1], "ollama", "the trusted list is kept")
    TestRunner:assertEqual(f._privacy_notice_pending, true, "the notice is owed")
    TestRunner:assertEqual(f._privacy_ask_migrated, true, "stamped")
end)

TestRunner:test("the Ask reset owes no notice when nothing was decided", function()
    local f = { behavior_migrated = true, _tools_posture_migrated = true }
    Migrations.run(f)
    TestRunner:assertEqual(f._privacy_ask_migrated, true, "stamped")
    TestRunner:assertEqual(f._privacy_notice_pending, nil, "no notice")
end)

TestRunner:test("legacy auto-X-Ray master ON -> one-way grant recorded, master OFF", function()
    local f = v020Fixture()
    Migrations.run(f)
    TestRunner:assertEqual(f._xray_auto_legacy_optin, true, "legacy grant")
    TestRunner:assertEqual(f.xray_auto_update, false, "master must switch off (new all-books meaning stays opt-in)")
end)

TestRunner:test("enable_tool_workflows=false -> chains to enable_book_tools=false, old keys removed", function()
    -- Two-hop chain in one launch: old bool -> posture "manual" -> binary false
    local f = v020Fixture()
    Migrations.run(f)
    TestRunner:assertEqual(f.enable_book_tools, false, "behavior-preserving off (chip starts off)")
    TestRunner:assertEqual(f.tools_posture, nil, "intermediate posture key consumed")
    TestRunner:assertEqual(f.enable_tool_workflows, nil, "old bool removed")
end)

TestRunner:test("enable_tool_workflows=true -> chains to enable_book_tools=true", function()
    local f = v020Fixture()
    f.enable_tool_workflows = true
    Migrations.run(f)
    TestRunner:assertEqual(f.enable_book_tools, true)
    TestRunner:assertEqual(f.tools_posture, nil, "intermediate posture key consumed")
end)

TestRunner:test("binary collapse maps every posture; nil stays nil (schema default true reachable)", function()
    for posture, expect in pairs({ auto = true, manual = false, off = false }) do
        local f = { _tools_posture_migrated = true, tools_posture = posture }
        Migrations.run(f)
        TestRunner:assertEqual(f.enable_book_tools, expect, "posture " .. posture)
        TestRunner:assertEqual(f.tools_posture, nil, "posture key consumed for " .. posture)
    end
    local f = { _tools_posture_migrated = true }
    Migrations.run(f)
    TestRunner:assertEqual(f.enable_book_tools, nil, "nil posture -> no explicit value baked")
    TestRunner:assertEqual(f._tools_binary_migrated, true, "stamped even with nothing to do")
end)

TestRunner:test("session chips seeded then rebuilt to canonical 7; spoiler toggle retired", function()
    local f = v020Fixture()
    Migrations.run(f)
    assertDeepEqual(f.session_chips, CANONICAL_CHIPS, "session_chips")
    TestRunner:assertEqual(f.show_spoiler_toggle, nil, "show_spoiler_toggle retired")
    TestRunner:assertEqual(f._dismissed_session_chips, nil, "full membership -> no dismissal seed")
end)

TestRunner:test("a chip added after the registry move is never seeded as dismissed", function()
    local f = v020Fixture()
    Migrations.run(f)
    -- the migration's list is frozen at the seven ids of its time: a chip
    -- appended to SESSION_CHIP_IDS later is injected for an upgrader, never
    -- seeded as dismissed (the id list is the guard; today's list is the same seven)
    local dismissed = {}
    for _idx, id in ipairs(f._dismissed_session_chips or {}) do dismissed[id] = true end
    TestRunner:assertEqual(next(dismissed), nil, "nothing seeded as dismissed")
    local Constants = require("koassistant.core.constants")
    local shown = {}
    for _idx, id in ipairs(Constants.resolveSessionChips(f.session_chips, f._dismissed_session_chips)) do
        shown[id] = true
    end
    for _idx, id in ipairs(Constants.SESSION_CHIP_IDS) do
        TestRunner:assertTrue(shown[id], id .. " rendered for an upgrader")
    end
end)

TestRunner:test("web_search_max_uses maps to the effort dial and is removed", function()
    local cases = { [2] = "light", [8] = "thorough", [5] = nil }  -- 4-7 = standard = nil
    for old_uses, effort in pairs(cases) do
        local f = v020Fixture()
        f.web_search_max_uses = old_uses
        Migrations.run(f)
        TestRunner:assertEqual(f.web_search_effort, effort, "uses=" .. old_uses)
        TestRunner:assertEqual(f.web_search_max_uses, nil, "old spinner key removed")
    end
end)

TestRunner:test("highlight context seeded from tuned dictionary context", function()
    local f = v020Fixture()
    Migrations.run(f)
    TestRunner:assertEqual(f.highlight_context_mode, "sentence")
    TestRunner:assertEqual(f.highlight_context_chars, 300)
    TestRunner:assertEqual(f.dictionary_context_mode, "sentence", "dictionary settings stay")
end)

TestRunner:test("highlight context NOT seeded from 'none' dictionary mode", function()
    local f = v020Fixture()
    f.dictionary_context_mode = "none"
    Migrations.run(f)
    TestRunner:assertEqual(f.highlight_context_mode, nil, "ambient context must stay opt-in")
end)

TestRunner:test("stored 'dictionary' bypass pick cleared to follow the new default", function()
    local f = v020Fixture()
    Migrations.run(f)
    TestRunner:assertEqual(f.dictionary_bypass_action, nil)
end)

TestRunner:test("unrelated settings ride through untouched", function()
    local f = v020Fixture()
    Migrations.run(f)
    TestRunner:assertEqual(f.translation_language, "German")
    TestRunner:assertEqual(f.ui_language, "auto")
    TestRunner:assertEqual(f._language_prompt_shown, true)
end)

--------------------------------------------------------------------------------
TestRunner:suite("Idempotence (second run is a no-op)")

TestRunner:test("v0.20.0 fixture: second run changes nothing", function()
    local f = v020Fixture()
    Migrations.run(f)
    local snapshot = deepCopy(f)
    local needs_save = Migrations.run(f)
    TestRunner:assertEqual(needs_save, false, "second run must not report changes")
    assertDeepEqual(f, snapshot, "second run must not mutate the table")
end)

TestRunner:test("fresh seed: second run changes nothing", function()
    local f = { behavior_migrated = true, _tools_posture_migrated = true }
    Migrations.run(f)
    local snapshot = deepCopy(f)
    local needs_save = Migrations.run(f)
    TestRunner:assertEqual(needs_save, false)
    assertDeepEqual(f, snapshot)
end)

--------------------------------------------------------------------------------
TestRunner:suite("Fresh-install seed (initSettings' virgin-table stamps)")

-- initSettings seeds ONLY these two stamps on a virgin table (defaults sweep M5):
-- without them the behavior migration would assign "full" (schema default is
-- "standard") and tools_posture would bake "manual" (schema default "auto"
-- unreachable). The rest of the chain is expected to fire harmlessly.
TestRunner:test("tools_posture stays nil (schema default 'auto' reachable)", function()
    local f = { behavior_migrated = true, _tools_posture_migrated = true }
    Migrations.run(f)
    TestRunner:assertEqual(f.tools_posture, nil)
end)

TestRunner:test("selected_behavior stays nil (read-through default)", function()
    local f = { behavior_migrated = true, _tools_posture_migrated = true }
    Migrations.run(f)
    TestRunner:assertEqual(f.selected_behavior, nil)
end)

TestRunner:test("no legacy X-Ray grant on fresh installs", function()
    local f = { behavior_migrated = true, _tools_posture_migrated = true }
    Migrations.run(f)
    TestRunner:assertEqual(f._xray_auto_legacy_optin, nil, "grant is upgrade-only")
    TestRunner:assertEqual(f._xray_auto_v2_migrated, true)
end)

TestRunner:test("chips seed to canonical 7; ui_language defaults to auto", function()
    local f = { behavior_migrated = true, _tools_posture_migrated = true }
    Migrations.run(f)
    assertDeepEqual(f.session_chips, CANONICAL_CHIPS)
    TestRunner:assertEqual(f.ui_language, "auto")
    TestRunner:assertEqual(f.web_search_effort, nil, "no old spinner -> standard default")
end)

--------------------------------------------------------------------------------
TestRunner:suite("Deliberate user choices survive")

TestRunner:test("legacy auto-X-Ray master OFF -> no grant, master untouched", function()
    local f = v020Fixture()
    f.xray_auto_update = false
    Migrations.run(f)
    TestRunner:assertEqual(f._xray_auto_legacy_optin, nil)
    TestRunner:assertEqual(f.xray_auto_update, false)
end)

TestRunner:test("deliberately removed chips seed the dismissal list, membership kept", function()
    local f = v020Fixture()
    f.session_chips = { "domain", "web_search" }
    f._session_chips_migrated = true
    f._session_chips_scope_v2 = true
    f._session_chips_attach_v1 = true
    f._session_chips_quick_v1 = true
    Migrations.run(f)
    assertDeepEqual(f.session_chips, { "domain", "web_search" },
        "membership must not be re-expanded")
    -- the canonical ids as of the registry migration (frozen there: a chip
    -- added later is injected, never seeded as dismissed)
    local expected = {}
    for _idx, id in ipairs(CANONICAL_CHIPS) do
        if id ~= "domain" and id ~= "web_search" then
            table.insert(expected, id)
        end
    end
    assertDeepEqual(f._dismissed_session_chips, expected,
        "dismissals = canonical ids minus membership (auto-injection must not resurrect)")
end)

TestRunner:test("re-picked dictionary bypass after the one-time clear sticks", function()
    local f = v020Fixture()
    Migrations.run(f)             -- clears the stored "dictionary", stamps the guard
    f.dictionary_bypass_action = "dictionary"  -- user re-picks it deliberately
    Migrations.run(f)
    TestRunner:assertEqual(f.dictionary_bypass_action, "dictionary",
        "guarded migration must not re-clear a deliberate re-pick")
end)

--------------------------------------------------------------------------------
TestRunner:suite("Prehistoric key cleanup")

TestRunner:test("translate_to migrates; stray transient view flags removed", function()
    local f = v020Fixture()
    f.translation_language = nil
    f.translate_to = "French"
    f.use_new_request_format = true
    f.compact_view = true
    f.dictionary_view = true
    f.minimal_buttons = true
    Migrations.run(f)
    TestRunner:assertEqual(f.translation_language, "French")
    TestRunner:assertEqual(f.translate_to, nil)
    TestRunner:assertEqual(f.use_new_request_format, nil)
    TestRunner:assertEqual(f.compact_view, nil)
    TestRunner:assertEqual(f.dictionary_view, nil)
    TestRunner:assertEqual(f.minimal_buttons, nil)
end)

TestRunner:test("translate_to never clobbers an existing translation_language", function()
    local f = v020Fixture()
    f.translate_to = "French"  -- fixture already has translation_language = "German"
    Migrations.run(f)
    TestRunner:assertEqual(f.translation_language, "German")
    TestRunner:assertEqual(f.translate_to, nil)
end)

--------------------------------------------------------------------------------
TestRunner:suite("Image Shape and Detail (image round S2)")

TestRunner:test("OpenAI's size and quality become Shape and Detail while OpenAI draws", function()
    local f = { image_gen_provider = "openai", image_gen_size = "1536x1024", image_gen_quality = "high" }
    TestRunner:assertTrue(Migrations.run(f))
    TestRunner:assertEqual(f.image_gen_shape, "landscape")
    TestRunner:assertEqual(f.image_gen_detail, "best")
    TestRunner:assertEqual(f.image_gen_size, nil)
    TestRunner:assertEqual(f.image_gen_quality, nil)
end)

TestRunner:test("the drawing provider's row first; OpenAI's quality stays OpenAI's", function()
    local f = { provider = "xai", image_gen_size = "1024x1024", image_gen_aspect = "9:16",
                image_gen_quality = "high" }
    Migrations.run(f)
    TestRunner:assertEqual(f.image_gen_shape, "portrait", "xAI draws: its aspect ratio wins")
    TestRunner:assertEqual(f.image_gen_detail, nil, "no other provider starts drawing at Best")
    TestRunner:assertEqual(f.image_gen_aspect, nil)
    TestRunner:assertEqual(f.image_gen_quality, nil)
end)

TestRunner:test("Default takes the new defaults; a Shape already set is kept", function()
    local f = { provider = "openai", image_gen_size = "default", image_gen_quality = "default" }
    Migrations.run(f)
    TestRunner:assertEqual(f.image_gen_shape, nil, "nil = Fit my screen")
    TestRunner:assertEqual(f.image_gen_detail, nil, "nil = Draft")
    TestRunner:assertEqual(f.image_gen_size, nil)
    f = { image_gen_shape = "square", image_gen_aspect = "16:9" }
    Migrations.run(f)
    TestRunner:assertEqual(f.image_gen_shape, "square")
    TestRunner:assertEqual(Migrations.run(f), false, "the old keys are gone: nothing runs again")
end)

TestRunner:suite("The right-to-left plain-text switches (B621)")

TestRunner:test("the three switches are cleared whatever their value; nothing without them", function()
    local f = { rtl_chat_text_mode = true, rtl_translate_text_mode = false, rtl_dictionary_text_mode = true,
                render_markdown = false, _privacy_ask_migrated = true, _reasoning_v2_migrated = true }
    TestRunner:assertTrue(Migrations.run(f), "a change")
    TestRunner:assertEqual(f.rtl_chat_text_mode, nil)
    TestRunner:assertEqual(f.rtl_translate_text_mode, nil)
    TestRunner:assertEqual(f.rtl_dictionary_text_mode, nil)
    TestRunner:assertEqual(f.render_markdown, false, "the reader's own View Mode is kept")
    local before = {}
    for k, v in pairs(f) do before[k] = v end
    Migrations.run(f)
    for k, v in pairs(before) do TestRunner:assertEqual(f[k], v, k .. " unchanged on the second run") end
end)

return TestRunner:summary()
