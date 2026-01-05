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

print("")
print(string.rep("=", 50))
print("  Unit Tests: system_prompts.lua")
print(string.rep("=", 50))

-- Test getBehavior()
TestRunner:suite("getBehavior()")

TestRunner:test("returns minimal variant", function()
    local result = SystemPrompts.getBehavior("minimal")
    TestRunner:assertContains(result, "helpful AI assistant", "minimal behavior")
end)

TestRunner:test("returns full variant", function()
    local result = SystemPrompts.getBehavior("full")
    TestRunner:assertContains(result, "ai_behavior", "full behavior should have xml tags")
end)

TestRunner:test("falls back to minimal for unknown variant", function()
    local result = SystemPrompts.getBehavior("unknown")
    TestRunner:assertContains(result, "helpful AI assistant", "unknown falls back to minimal")
end)

TestRunner:test("falls back to minimal for nil", function()
    local result = SystemPrompts.getBehavior(nil)
    TestRunner:assertContains(result, "helpful AI assistant", "nil falls back to minimal")
end)

TestRunner:test("returns custom text for custom variant", function()
    local result = SystemPrompts.getBehavior("custom", "My custom behavior")
    TestRunner:assertEqual(result, "My custom behavior", "custom variant returns custom_text")
end)

TestRunner:test("custom variant falls back to minimal if no custom_text", function()
    local result = SystemPrompts.getBehavior("custom", nil)
    TestRunner:assertContains(result, "helpful AI assistant", "custom without text falls back")
end)

-- Test resolveBehavior()
TestRunner:suite("resolveBehavior()")

TestRunner:test("priority 1: behavior_override takes precedence", function()
    local text, source = SystemPrompts.resolveBehavior({
        behavior_override = "My override text",
        behavior_variant = "full",
        global_variant = "minimal",
    })
    TestRunner:assertEqual(text, "My override text", "override text")
    TestRunner:assertEqual(source, "override", "source is override")
end)

TestRunner:test("priority 2: behavior_variant overrides global", function()
    local text, source = SystemPrompts.resolveBehavior({
        behavior_variant = "minimal",
        global_variant = "full",
    })
    TestRunner:assertContains(text, "helpful AI assistant", "minimal variant")
    TestRunner:assertEqual(source, "variant", "source is variant")
end)

TestRunner:test("priority 3: falls back to global_variant", function()
    local text, source = SystemPrompts.resolveBehavior({
        global_variant = "full",
    })
    TestRunner:assertContains(text, "ai_behavior", "full from global")
    TestRunner:assertEqual(source, "global", "source is global")
end)

TestRunner:test("behavior_variant=none disables behavior", function()
    local text, source = SystemPrompts.resolveBehavior({
        behavior_variant = "none",
        global_variant = "full",
    })
    TestRunner:assertNil(text, "text should be nil")
    TestRunner:assertEqual(source, "none", "source is none")
end)

TestRunner:test("behavior_variant=custom uses custom_ai_behavior", function()
    local text, source = SystemPrompts.resolveBehavior({
        behavior_variant = "custom",
        custom_ai_behavior = "User custom behavior",
        global_variant = "full",
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

TestRunner:test("empty config uses full as default", function()
    local text, source = SystemPrompts.resolveBehavior({})
    TestRunner:assertContains(text, "ai_behavior", "default is full")
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
    local primary, list = SystemPrompts.parseUserLanguages("English, German, French", nil)
    TestRunner:assertEqual(primary, "English", "first is primary")
    TestRunner:assertContains(list, "German", "list contains German")
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
    local result = SystemPrompts.buildLanguageInstruction("English, German", nil)
    TestRunner:assertContains(result, "The user speaks:", "starts with user speaks")
    TestRunner:assertContains(result, "English, German", "contains languages")
    TestRunner:assertContains(result, "respond in English", "primary in response")
end)

TestRunner:test("respects primary_override", function()
    local result = SystemPrompts.buildLanguageInstruction("English, German", "German")
    TestRunner:assertContains(result, "respond in German", "override primary")
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
    TestRunner:assertContains(result.text, "The user speaks:", "language in text")
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

TestRunner:test("returns empty array when behavior=none and no domain", function()
    local result = SystemPrompts.buildAnthropicSystemArray({
        behavior_variant = "none",
    })
    TestRunner:assertEqual(#result, 0, "empty array")
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
    TestRunner:assertEqual(#result[1].debug_components, 2, "two components")
end)

-- Test buildFlattenedPrompt()
TestRunner:suite("buildFlattenedPrompt()")

TestRunner:test("returns combined string", function()
    local result = SystemPrompts.buildFlattenedPrompt({
        behavior_variant = "minimal",
        domain_context = "Test domain",
    })
    TestRunner:assertType(result, "string", "returns string")
    TestRunner:assertContains(result, "helpful AI assistant", "has behavior")
    TestRunner:assertContains(result, "Test domain", "has domain")
end)

TestRunner:test("returns empty string when behavior=none and no domain", function()
    local result = SystemPrompts.buildFlattenedPrompt({
        behavior_variant = "none",
    })
    TestRunner:assertEqual(result, "", "empty string")
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

-- Test getVariantNames()
TestRunner:suite("getVariantNames()")

TestRunner:test("returns array of variant names", function()
    local result = SystemPrompts.getVariantNames()
    TestRunner:assertType(result, "table", "returns table")
    -- Should have at least minimal and full
    local has_minimal = false
    local has_full = false
    for _, name in ipairs(result) do
        if name == "minimal" then has_minimal = true end
        if name == "full" then has_full = true end
    end
    if not has_minimal then error("missing minimal") end
    if not has_full then error("missing full") end
end)

-- Summary
local success = TestRunner:summary()
return success
