-- Unit tests for prompts/system_prompts.lua
-- Tests behavior resolution, language parsing, and unified system building
-- No API calls - pure logic testing

-- Setup paths (detect script location)
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")

    return plugin_dir, tests_dir
end

setupPaths()

-- Load mocks BEFORE any plugin modules
require("mock_koreader")

-- Simple test framework
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
        print(string.format("    ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("    ✗ %s", name))
        print(string.format("      Error: %s", tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(string.format("%s: expected %q, got %q", msg or "Assertion failed", tostring(expected), tostring(actual)))
    end
end

function TestRunner:assertContains(str, pattern, msg)
    if not str or not str:find(pattern, 1, true) then
        error(string.format("%s: expected string to contain %q", msg or "Assertion failed", pattern))
    end
end

function TestRunner:assertNil(value, msg)
    if value ~= nil then
        error(string.format("%s: expected nil, got %q", msg or "Assertion failed", tostring(value)))
    end
end

function TestRunner:assertNotNil(value, msg)
    if value == nil then
        error(string.format("%s: expected non-nil value", msg or "Assertion failed"))
    end
end

function TestRunner:assertType(value, expected_type, msg)
    if type(value) ~= expected_type then
        error(string.format("%s: expected type %q, got %q", msg or "Assertion failed", expected_type, type(value)))
    end
end

function TestRunner:summary()
    print("")
    print(string.rep("-", 50))
    local total = self.passed + self.failed
    if self.failed == 0 then
        print(string.format("  All %d tests passed!", total))
    else
        print(string.format("  %d passed, %d failed (of %d total)", self.passed, self.failed, total))
    end
    return self.failed == 0
end

-- Load the module under test
local SystemPrompts = require("prompts.system_prompts")
local BehaviorLoader = require("behavior_loader")

-- Load actual behaviors dynamically (same as plugin does)
local BUILTIN_BEHAVIORS = BehaviorLoader.loadBuiltin()

-- Get a sample behavior for testing (first available)
local function getFirstBehaviorId()
    local id = next(BUILTIN_BEHAVIORS)
    return id
end

local function getFirstBehaviorText()
    local id = next(BUILTIN_BEHAVIORS)
    return id and BUILTIN_BEHAVIORS[id].text or nil
end

-- Get specific behavior if it exists, otherwise first available
local function getBehaviorIdOr(preferred, fallback)
    if BUILTIN_BEHAVIORS[preferred] then
        return preferred
    end
    return fallback or getFirstBehaviorId()
end

print("")
print(string.rep("=", 50))
print("  Unit Tests: system_prompts.lua")
print(string.rep("=", 50))

-- Test getBehavior()
TestRunner:suite("getBehavior()")

TestRunner:test("returns behavior by ID", function()
    local id = getFirstBehaviorId()
    if not id then error("no built-in behaviors found") end
    local result = SystemPrompts.getBehavior(id)
    TestRunner:assertType(result, "string", "returns string")
    TestRunner:assertEqual(result, BUILTIN_BEHAVIORS[id].text, "matches loaded behavior")
end)

TestRunner:test("returns full variant if exists", function()
    if not BUILTIN_BEHAVIORS["full"] then return end  -- Skip if not available
    local result = SystemPrompts.getBehavior("full")
    TestRunner:assertEqual(result, BUILTIN_BEHAVIORS["full"].text, "full behavior matches")
end)

TestRunner:test("falls back for unknown variant", function()
    local result = SystemPrompts.getBehavior("unknown_nonexistent_variant")
    local expected = getFirstBehaviorText()
    TestRunner:assertType(result, "string", "returns string")
    -- Should return some fallback behavior
    TestRunner:assertNotNil(result, "unknown falls back to something")
end)

TestRunner:test("returns fallback for nil", function()
    local result = SystemPrompts.getBehavior(nil)
    TestRunner:assertType(result, "string", "returns string for nil")
    TestRunner:assertNotNil(result, "nil returns fallback")
end)

TestRunner:test("returns custom text for custom variant", function()
    local result = SystemPrompts.getBehavior("custom", "My custom behavior")
    TestRunner:assertEqual(result, "My custom behavior", "custom variant returns custom_text")
end)

TestRunner:test("custom variant falls back if no custom_text", function()
    local result = SystemPrompts.getBehavior("custom", nil)
    TestRunner:assertType(result, "string", "returns string")
    TestRunner:assertNotNil(result, "custom without text falls back")
end)

-- Test resolveBehavior()
TestRunner:suite("resolveBehavior()")

TestRunner:test("priority 1: behavior_override takes precedence", function()
    local id1 = getBehaviorIdOr("full", getFirstBehaviorId())
    local id2 = getBehaviorIdOr("mini", getFirstBehaviorId())
    local text, source = SystemPrompts.resolveBehavior({
        behavior_override = "My override text",
        behavior_variant = id1,
        global_variant = id2,
    })
    TestRunner:assertEqual(text, "My override text", "override text")
    TestRunner:assertEqual(source, "override", "source is override")
end)

TestRunner:test("priority 2: behavior_variant overrides global", function()
    local variant_id = getFirstBehaviorId()
    local global_id = getBehaviorIdOr("full", variant_id)
    if variant_id == global_id then
        -- Need different IDs for this test
        for id in pairs(BUILTIN_BEHAVIORS) do
            if id ~= variant_id then global_id = id break end
        end
    end
    local text, source = SystemPrompts.resolveBehavior({
        behavior_variant = variant_id,
        global_variant = global_id,
    })
    TestRunner:assertEqual(text, BUILTIN_BEHAVIORS[variant_id].text, "variant text matches")
    TestRunner:assertEqual(source, "variant", "source is variant")
end)

TestRunner:test("priority 3: falls back to global_variant", function()
    local global_id = getBehaviorIdOr("full", getFirstBehaviorId())
    local text, source = SystemPrompts.resolveBehavior({
        global_variant = global_id,
    })
    TestRunner:assertEqual(text, BUILTIN_BEHAVIORS[global_id].text, "global text matches")
    TestRunner:assertEqual(source, "global", "source is global")
end)

TestRunner:test("behavior_variant=none disables behavior", function()
    local global_id = getBehaviorIdOr("full", getFirstBehaviorId())
    local text, source = SystemPrompts.resolveBehavior({
        behavior_variant = "none",
        global_variant = global_id,
    })
    TestRunner:assertNil(text, "text should be nil")
    TestRunner:assertEqual(source, "none", "source is none")
end)

TestRunner:test("behavior_variant=custom uses custom_ai_behavior", function()
    local global_id = getBehaviorIdOr("full", getFirstBehaviorId())
    local text, source = SystemPrompts.resolveBehavior({
        behavior_variant = "custom",
        custom_ai_behavior = "User custom behavior",
        global_variant = global_id,
    })
    TestRunner:assertEqual(text, "User custom behavior", "custom behavior text")
    TestRunner:assertEqual(source, "variant", "source is variant")
end)

TestRunner:test("global_variant=custom uses custom_ai_behavior", function()
    local text, source = SystemPrompts.resolveBehavior({
        global_variant = "custom",
        custom_ai_behavior = "Global custom behavior",
    })
    TestRunner:assertEqual(text, "Global custom behavior", "global custom text")
    TestRunner:assertEqual(source, "global", "source is global")
end)

TestRunner:test("empty config uses standard as default", function()
    local text, source = SystemPrompts.resolveBehavior({})
    -- Default is "standard" per main.lua, should match that behavior
    local expected_id = getBehaviorIdOr("standard", getFirstBehaviorId())
    TestRunner:assertEqual(text, BUILTIN_BEHAVIORS[expected_id].text, "default matches standard behavior")
    TestRunner:assertEqual(source, "global", "source is global")
end)

-- Test parseUserLanguages()
TestRunner:suite("parseUserLanguages()")

TestRunner:test("single language", function()
    local primary, list = SystemPrompts.parseUserLanguages("English", nil)
    TestRunner:assertEqual(primary, "English", "primary")
    TestRunner:assertEqual(list, "English", "list")
end)

TestRunner:test("multiple languages, first is primary", function()
    -- parseUserLanguages returns 3 values: (primary_id, primary_display, languages_list)
    -- languages_list uses native script (e.g., "Deutsch" for German)
    local primary, primary_display, list = SystemPrompts.parseUserLanguages("English, German, French", nil)
    TestRunner:assertEqual(primary, "English", "first is primary")
    TestRunner:assertContains(list, "Deutsch", "list contains German (in native script)")
end)

TestRunner:test("primary_override changes primary", function()
    local primary, list = SystemPrompts.parseUserLanguages("English, German, French", "German")
    TestRunner:assertEqual(primary, "German", "override to German")
end)

TestRunner:test("invalid override ignored", function()
    local primary, list = SystemPrompts.parseUserLanguages("English, German", "Spanish")
    TestRunner:assertEqual(primary, "English", "invalid override ignored")
end)

TestRunner:test("empty string returns English", function()
    local primary, list = SystemPrompts.parseUserLanguages("", nil)
    TestRunner:assertEqual(primary, "English", "default English")
end)

TestRunner:test("nil returns English", function()
    local primary, list = SystemPrompts.parseUserLanguages(nil, nil)
    TestRunner:assertEqual(primary, "English", "default English")
end)

TestRunner:test("trims whitespace", function()
    local primary, list = SystemPrompts.parseUserLanguages("  English  ,  German  ", nil)
    TestRunner:assertEqual(primary, "English", "trimmed primary")
end)

-- Test buildLanguageInstruction()
TestRunner:suite("buildLanguageInstruction()")

TestRunner:test("builds instruction with primary", function()
    -- buildLanguageInstruction uses English names (not native script) for AI clarity
    local result = SystemPrompts.buildLanguageInstruction("English, German", nil)
    TestRunner:assertContains(result, "The user understands:", "contains user understands")
    TestRunner:assertContains(result, "English, German", "contains languages in English")
    TestRunner:assertContains(result, "respond in English", "primary in response")
end)

TestRunner:test("respects primary_override", function()
    -- Language instruction uses English names for AI clarity
    local result = SystemPrompts.buildLanguageInstruction("English, German", "German")
    TestRunner:assertContains(result, "respond in German", "override primary (English name)")
end)

-- Test getCacheableContent()
TestRunner:suite("getCacheableContent()")

TestRunner:test("behavior + domain combined", function()
    local result = SystemPrompts.getCacheableContent("Behavior text", "Domain context")
    TestRunner:assertContains(result, "Behavior text", "has behavior")
    TestRunner:assertContains(result, "Domain context", "has domain")
    TestRunner:assertContains(result, "---", "has separator")
end)

TestRunner:test("behavior only", function()
    local result = SystemPrompts.getCacheableContent("Behavior text", nil)
    TestRunner:assertEqual(result, "Behavior text", "behavior only")
end)

TestRunner:test("domain only", function()
    local result = SystemPrompts.getCacheableContent(nil, "Domain context")
    TestRunner:assertEqual(result, "Domain context", "domain only")
end)

TestRunner:test("returns nil when both empty", function()
    local result = SystemPrompts.getCacheableContent(nil, nil)
    TestRunner:assertNil(result, "nil when both empty")
end)

TestRunner:test("empty strings treated as nil", function()
    local result = SystemPrompts.getCacheableContent("", "")
    TestRunner:assertNil(result, "nil for empty strings")
end)

-- Test buildUnifiedSystem()
TestRunner:suite("buildUnifiedSystem()")

TestRunner:test("returns complete structure", function()
    local result = SystemPrompts.buildUnifiedSystem({
        behavior_variant = "minimal",
    })
    TestRunner:assertType(result, "table", "returns table")
    TestRunner:assertNotNil(result.text, "has text")
    TestRunner:assertNotNil(result.enable_caching, "has enable_caching")
    TestRunner:assertNotNil(result.components, "has components")
end)

TestRunner:test("includes behavior in components", function()
    local result = SystemPrompts.buildUnifiedSystem({
        behavior_variant = "minimal",
    })
    TestRunner:assertNotNil(result.components.behavior, "behavior component")
end)

TestRunner:test("includes domain in components", function()
    local result = SystemPrompts.buildUnifiedSystem({
        behavior_variant = "minimal",
        domain_context = "Test domain",
    })
    TestRunner:assertEqual(result.components.domain, "Test domain", "domain component")
    TestRunner:assertContains(result.text, "Test domain", "domain in text")
end)

TestRunner:test("includes language in components", function()
    local result = SystemPrompts.buildUnifiedSystem({
        behavior_variant = "minimal",
        user_languages = "English, Spanish",
    })
    TestRunner:assertNotNil(result.components.language, "language component")
    TestRunner:assertContains(result.text, "The user understands:", "language in text")
end)

TestRunner:test("behavior=none excludes behavior from components", function()
    local result = SystemPrompts.buildUnifiedSystem({
        behavior_variant = "none",
        domain_context = "Test domain",
    })
    TestRunner:assertNil(result.components.behavior, "no behavior component")
    TestRunner:assertEqual(result.components.domain, "Test domain", "domain still present")
end)

TestRunner:test("enable_caching defaults to true", function()
    local result = SystemPrompts.buildUnifiedSystem({})
    TestRunner:assertEqual(result.enable_caching, true, "caching enabled")
end)

TestRunner:test("enable_caching can be disabled", function()
    local result = SystemPrompts.buildUnifiedSystem({
        enable_caching = false,
    })
    TestRunner:assertEqual(result.enable_caching, false, "caching disabled")
end)

TestRunner:test("skip_language_instruction excludes language from system", function()
    local result = SystemPrompts.buildUnifiedSystem({
        behavior_variant = "minimal",
        user_languages = "English, German",
        skip_language_instruction = true,
    })
    TestRunner:assertNil(result.components.language, "no language component when skipped")
    -- Text should not contain language instruction
    if result.text:find("The user understands:") then
        error("language instruction should be skipped")
    end
end)

TestRunner:test("skip_language_instruction=false includes language", function()
    local result = SystemPrompts.buildUnifiedSystem({
        behavior_variant = "minimal",
        user_languages = "English, German",
        skip_language_instruction = false,
    })
    TestRunner:assertNotNil(result.components.language, "has language component")
    TestRunner:assertContains(result.text, "The user understands:", "has language instruction")
end)

TestRunner:test("skip_language_instruction=nil includes language (default)", function()
    local result = SystemPrompts.buildUnifiedSystem({
        behavior_variant = "minimal",
        user_languages = "English, German",
        -- skip_language_instruction not set (nil)
    })
    TestRunner:assertNotNil(result.components.language, "has language component by default")
end)

-- Test buildAnthropicSystemArray()
TestRunner:suite("buildAnthropicSystemArray()")

TestRunner:test("returns array with single block", function()
    local result = SystemPrompts.buildAnthropicSystemArray({
        behavior_variant = "minimal",
    })
    TestRunner:assertType(result, "table", "returns table")
    TestRunner:assertEqual(#result, 1, "single block")
end)

TestRunner:test("block has cache_control when caching enabled", function()
    local result = SystemPrompts.buildAnthropicSystemArray({
        behavior_variant = "minimal",
        enable_caching = true,
    })
    TestRunner:assertNotNil(result[1].cache_control, "has cache_control")
    TestRunner:assertEqual(result[1].cache_control.type, "ephemeral", "ephemeral cache")
end)

TestRunner:test("block has no cache_control when caching disabled", function()
    local result = SystemPrompts.buildAnthropicSystemArray({
        behavior_variant = "minimal",
        enable_caching = false,
    })
    TestRunner:assertNil(result[1].cache_control, "no cache_control")
end)

TestRunner:test("returns language-only block when behavior=none and no domain", function()
    local result = SystemPrompts.buildAnthropicSystemArray({
        behavior_variant = "none",
    })
    -- Language instruction is always generated (auto-detects from KOReader)
    TestRunner:assertEqual(#result, 1, "one block (language only)")
    TestRunner:assertContains(result[1].text, "respond in", "has language instruction")
end)

TestRunner:test("returns array with domain when behavior=none", function()
    local result = SystemPrompts.buildAnthropicSystemArray({
        behavior_variant = "none",
        domain_context = "Test domain",
    })
    TestRunner:assertEqual(#result, 1, "one block")
    TestRunner:assertContains(result[1].text, "Test domain", "domain in text")
end)

TestRunner:test("block has debug_components", function()
    local result = SystemPrompts.buildAnthropicSystemArray({
        behavior_variant = "minimal",
        domain_context = "Test domain",
    })
    TestRunner:assertNotNil(result[1].debug_components, "has debug_components")
    -- behavior + domain + language (language always generated via auto-detect)
    TestRunner:assertEqual(#result[1].debug_components, 3, "three components")
end)

-- Test buildFlattenedPrompt()
TestRunner:suite("buildFlattenedPrompt()")

TestRunner:test("returns combined string", function()
    local behavior_id = getFirstBehaviorId()
    local result = SystemPrompts.buildFlattenedPrompt({
        behavior_variant = behavior_id,
        domain_context = "Test domain",
    })
    TestRunner:assertType(result, "string", "returns string")
    -- Should contain behavior text (dynamic check)
    TestRunner:assertContains(result, BUILTIN_BEHAVIORS[behavior_id].text:sub(1, 20), "has behavior")
    TestRunner:assertContains(result, "Test domain", "has domain")
end)

TestRunner:test("returns language instruction when behavior=none and no domain", function()
    local result = SystemPrompts.buildFlattenedPrompt({
        behavior_variant = "none",
    })
    -- Language instruction is always generated (auto-detects from KOReader)
    TestRunner:assertContains(result, "respond in", "has language instruction")
end)

-- Test getEffectiveTranslationLanguage()
TestRunner:suite("getEffectiveTranslationLanguage()")

TestRunner:test("uses primary when translation_use_primary is true", function()
    local result = SystemPrompts.getEffectiveTranslationLanguage({
        translation_use_primary = true,
        user_languages = "German, English",
    })
    TestRunner:assertEqual(result, "German", "uses primary")
end)

TestRunner:test("uses translation_language when translation_use_primary is false", function()
    local result = SystemPrompts.getEffectiveTranslationLanguage({
        translation_use_primary = false,
        translation_language = "Spanish",
        user_languages = "German, English",
    })
    TestRunner:assertEqual(result, "Spanish", "uses translation_language")
end)

TestRunner:test("defaults to English if no translation_language", function()
    local result = SystemPrompts.getEffectiveTranslationLanguage({
        translation_use_primary = false,
    })
    TestRunner:assertEqual(result, "English", "defaults to English")
end)

TestRunner:test("resolves __PRIMARY__ sentinel to actual language", function()
    local result = SystemPrompts.getEffectiveTranslationLanguage({
        translation_use_primary = false,
        translation_language = "__PRIMARY__",
        user_languages = "German, English",
    })
    TestRunner:assertEqual(result, "German", "resolves __PRIMARY__ to primary language")
end)

TestRunner:test("resolves __PRIMARY__ with explicit primary_language override", function()
    local result = SystemPrompts.getEffectiveTranslationLanguage({
        translation_use_primary = false,
        translation_language = "__PRIMARY__",
        user_languages = "German, English",
        primary_language = "English",
    })
    TestRunner:assertEqual(result, "English", "uses explicit primary override")
end)

TestRunner:test("resolves empty string to primary language", function()
    local result = SystemPrompts.getEffectiveTranslationLanguage({
        translation_use_primary = false,
        translation_language = "",
        user_languages = "French, German",
    })
    TestRunner:assertEqual(result, "French", "empty string uses primary")
end)

-- Test getVariantNames()
TestRunner:suite("getVariantNames()")

TestRunner:test("returns array of variant names", function()
    local result = SystemPrompts.getVariantNames()
    TestRunner:assertType(result, "table", "returns table")
    -- Should have at least some built-in behaviors
    if #result == 0 then error("no variant names found") end
    -- Verify first item exists in BUILTIN_BEHAVIORS
    local first = result[1]
    TestRunner:assertNotNil(BUILTIN_BEHAVIORS[first], "first variant exists in builtins")
end)

-- Test getAllBehaviors()
TestRunner:suite("getAllBehaviors()")

TestRunner:test("returns built-in behaviors", function()
    local result = SystemPrompts.getAllBehaviors(nil)
    TestRunner:assertType(result, "table", "returns table")
    -- Should have at least one behavior
    local count = 0
    for _ in pairs(result) do count = count + 1 end
    if count == 0 then error("no behaviors returned") end
    -- Verify first builtin is present
    local first_id = getFirstBehaviorId()
    TestRunner:assertNotNil(result[first_id], "has first builtin: " .. first_id)
end)

TestRunner:test("built-in behaviors have correct structure", function()
    local result = SystemPrompts.getAllBehaviors(nil)
    local first_id = getFirstBehaviorId()
    local behavior = result[first_id]
    TestRunner:assertEqual(behavior.id, first_id, "id matches")
    TestRunner:assertEqual(behavior.source, "builtin", "source is builtin")
    TestRunner:assertNotNil(behavior.text, "has text")
    TestRunner:assertNotNil(behavior.display_name, "has display_name")
end)

TestRunner:test("includes UI-created behaviors", function()
    local custom = {
        { id = "custom_1", name = "My Custom", text = "Custom behavior text" },
    }
    local result = SystemPrompts.getAllBehaviors(custom)
    TestRunner:assertNotNil(result["custom_1"], "has custom behavior")
    TestRunner:assertEqual(result["custom_1"].source, "ui", "source is ui")
    TestRunner:assertEqual(result["custom_1"].text, "Custom behavior text", "text matches")
end)

TestRunner:test("UI-created behaviors get (custom) suffix in display_name", function()
    local custom = {
        { id = "custom_1", name = "My Custom", text = "Custom text" },
    }
    local result = SystemPrompts.getAllBehaviors(custom)
    TestRunner:assertContains(result["custom_1"].display_name, "(custom)", "has custom suffix")
end)

TestRunner:test("handles nil custom_behaviors", function()
    local result = SystemPrompts.getAllBehaviors(nil)
    TestRunner:assertType(result, "table", "returns table")
    local first_id = getFirstBehaviorId()
    TestRunner:assertNotNil(result[first_id], "has built-ins: " .. first_id)
end)

TestRunner:test("handles empty custom_behaviors array", function()
    local result = SystemPrompts.getAllBehaviors({})
    TestRunner:assertType(result, "table", "returns table")
    local first_id = getFirstBehaviorId()
    TestRunner:assertNotNil(result[first_id], "has built-ins: " .. first_id)
end)

-- Test getSortedBehaviors()
TestRunner:suite("getSortedBehaviors()")

TestRunner:test("returns array sorted by source then name", function()
    local custom = {
        { id = "custom_1", name = "Zebra", text = "text" },
        { id = "custom_2", name = "Alpha", text = "text" },
    }
    local result = SystemPrompts.getSortedBehaviors(custom)
    TestRunner:assertType(result, "table", "returns table")
    -- Built-ins should come first
    local first_source = result[1].source
    TestRunner:assertEqual(first_source, "builtin", "built-ins first")
end)

TestRunner:test("UI behaviors appear after built-ins", function()
    local custom = {
        { id = "custom_1", name = "My Custom", text = "text" },
    }
    local result = SystemPrompts.getSortedBehaviors(custom)
    -- Find positions
    local builtin_pos, ui_pos
    for i, b in ipairs(result) do
        if b.source == "builtin" and not builtin_pos then builtin_pos = i end
        if b.source == "ui" then ui_pos = i end
    end
    if ui_pos and builtin_pos and ui_pos < builtin_pos then
        error("UI should come after built-ins")
    end
end)

TestRunner:test("returns all behaviors", function()
    local custom = {
        { id = "custom_1", name = "Custom 1", text = "text" },
    }
    local result = SystemPrompts.getSortedBehaviors(custom)
    -- Should have at least the builtins + 1 custom
    local builtin_count = 0
    for _ in pairs(BUILTIN_BEHAVIORS) do builtin_count = builtin_count + 1 end
    if #result < builtin_count + 1 then
        error("expected at least " .. (builtin_count + 1) .. " behaviors, got " .. #result)
    end
end)

-- Test getBehaviorById()
TestRunner:suite("getBehaviorById()")

TestRunner:test("returns built-in behavior by ID", function()
    local first_id = getFirstBehaviorId()
    local result = SystemPrompts.getBehaviorById(first_id, nil)
    TestRunner:assertNotNil(result, "found " .. first_id)
    TestRunner:assertEqual(result.id, first_id, "id matches")
    TestRunner:assertEqual(result.source, "builtin", "source is builtin")
    TestRunner:assertNotNil(result.text, "has text")
end)

TestRunner:test("returns UI-created behavior by ID", function()
    local custom = {
        { id = "custom_1", name = "My Custom", text = "My custom text" },
    }
    local result = SystemPrompts.getBehaviorById("custom_1", custom)
    TestRunner:assertNotNil(result, "found custom")
    TestRunner:assertEqual(result.id, "custom_1", "id matches")
    TestRunner:assertEqual(result.source, "ui", "source is ui")
    TestRunner:assertEqual(result.text, "My custom text", "text matches")
end)

TestRunner:test("returns nil for unknown ID", function()
    local result = SystemPrompts.getBehaviorById("nonexistent", nil)
    TestRunner:assertNil(result, "nil for unknown")
end)

TestRunner:test("returns nil for nil ID", function()
    local result = SystemPrompts.getBehaviorById(nil, nil)
    TestRunner:assertNil(result, "nil for nil ID")
end)

TestRunner:test("built-in takes priority over custom with same ID", function()
    -- Edge case: if someone creates a custom with same ID as built-in
    local builtin_id = getFirstBehaviorId()
    if not builtin_id then error("no built-in behaviors found") end
    local custom = {
        { id = builtin_id, name = "Fake Builtin", text = "Fake text" },
    }
    local result = SystemPrompts.getBehaviorById(builtin_id, custom)
    -- Built-in should win
    TestRunner:assertEqual(result.source, "builtin", "built-in wins")
end)

-- Test resolveBehavior() with custom_behaviors array
TestRunner:suite("resolveBehavior() with custom_behaviors")

TestRunner:test("resolves UI-created behavior by ID in variant", function()
    local custom = {
        { id = "custom_1", name = "My Custom", text = "Custom behavior text" },
    }
    local text, source = SystemPrompts.resolveBehavior({
        behavior_variant = "custom_1",
        custom_behaviors = custom,
    })
    TestRunner:assertEqual(text, "Custom behavior text", "custom text resolved")
    TestRunner:assertEqual(source, "variant", "source is variant")
end)

TestRunner:test("resolves UI-created behavior by ID in global_variant", function()
    local custom = {
        { id = "custom_1", name = "My Custom", text = "Custom behavior text" },
    }
    local text, source = SystemPrompts.resolveBehavior({
        global_variant = "custom_1",
        custom_behaviors = custom,
    })
    TestRunner:assertEqual(text, "Custom behavior text", "custom text resolved")
    TestRunner:assertEqual(source, "global", "source is global")
end)

TestRunner:test("falls back to fallback for unknown custom ID", function()
    local text, source = SystemPrompts.resolveBehavior({
        behavior_variant = "nonexistent_custom",
        custom_behaviors = {},
    })
    -- Should fall through to global default (some fallback behavior)
    TestRunner:assertType(text, "string", "falls back to string")
    TestRunner:assertNotNil(text, "falls back to something")
    -- Verify it's one of the actual built-in behaviors
    local found = false
    for _, behavior in pairs(BUILTIN_BEHAVIORS) do
        if behavior.text == text then
            found = true
            break
        end
    end
    if not found then
        error("fallback text doesn't match any built-in behavior")
    end
end)

-- Test skip_domain behavior
TestRunner:suite("buildUnifiedSystem() skip_domain")

TestRunner:test("domain_context present appears in result", function()
    local result = SystemPrompts.buildUnifiedSystem({
        behavior_variant = "minimal",
        domain_context = "Science fiction analysis",
    })
    TestRunner:assertContains(result.text, "Science fiction analysis", "domain in text")
    TestRunner:assertEqual(result.components.domain, "Science fiction analysis", "domain component")
end)

TestRunner:test("domain_context=nil results in no domain component", function()
    local result = SystemPrompts.buildUnifiedSystem({
        behavior_variant = "minimal",
        -- domain_context not set (nil)
    })
    TestRunner:assertNil(result.components.domain, "no domain component when nil")
end)

TestRunner:test("domain_context='' excluded from text output", function()
    local result = SystemPrompts.buildUnifiedSystem({
        behavior_variant = "minimal",
        domain_context = "",
    })
    -- getCacheableContent treats empty string same as nil (no domain in combined text)
    -- but components.domain stores the raw value for debugging
    -- Verify domain doesn't appear in the combined text via separator
    if result.text:find("---", 1, true) then
        error("empty domain should not add separator to text")
    end
end)

TestRunner:test("skip_domain + skip_language_instruction combined excludes both", function()
    local result = SystemPrompts.buildUnifiedSystem({
        behavior_variant = "minimal",
        domain_context = "Physics",
        user_languages = "English, German",
        skip_language_instruction = true,
        -- skip_domain is simulated by not passing domain_context
        -- The actual skip_domain flag is handled in the caller (dialogs.lua)
        -- which simply doesn't pass domain_context to buildUnifiedSystem
    })
    -- Language should be skipped
    TestRunner:assertNil(result.components.language, "no language when skipped")
    -- Domain IS present since we passed it (skip_domain is caller-side)
    -- This test verifies skip_language_instruction works independently
    TestRunner:assertEqual(result.components.domain, "Physics", "domain still present")
end)

-- Summary
local success = TestRunner:summary()
return success
