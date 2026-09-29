-- Unit tests for ActionService.getActionDisplayText (audit quick win): pure,
-- static, high-branch, previously untested. A lying badge is a trust bug.

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")

local ActionService = require("action_service")
local DT = ActionService.getActionDisplayText

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:eq(a, b, msg)
    if a ~= b then error(string.format("%s: expected %s, got %s",
        msg or "eq", tostring(b), tostring(a)), 2) end
end
function TestRunner:has(s, sub, msg)
    if not s:find(sub, 1, true) then error((msg or "missing") .. ": " .. sub .. " in " .. s, 2) end
end
function TestRunner:hasnt(s, sub, msg)
    if s:find(sub, 1, true) then error((msg or "unexpected") .. ": " .. sub .. " in " .. s, 2) end
end

local IND = { enable_data_access_indicators = true }

print("")
print(string.rep("=", 50))
print("  Unit Tests: Action Display Text")
print(string.rep("=", 50))

TestRunner:test("indicators off: bare text, whatever the flags", function()
    TestRunner:eq(DT({ text = "Explain", use_book_text = true, use_annotations = true }, {}), "Explain")
    TestRunner:eq(DT({ text = "Explain", use_book_text = true },
        { enable_data_access_indicators = false }), "Explain")
end)

TestRunner:test("annotations show one icon, never the highlights icon too", function()
    local s = DT({ text = "A", use_highlights = true, use_annotations = true }, IND)
    TestRunner:has(s, "📝", "annotations icon")
    TestRunner:hasnt(s, "🔖", "highlights icon suppressed when annotations shown")
    local h = DT({ text = "A", use_highlights = true }, IND)
    TestRunner:has(h, "🔖", "highlights-only icon")
end)

TestRunner:test("forced web: solid globe regardless of opts", function()
    local s = DT({ text = "A", enable_web_search = true }, IND,
        { effective_web_search = false, quick_web_strip = true })
    TestRunner:has(s, "🌐", "solid globe")
    TestRunner:hasnt(s, "(🌐)", "not the parenthesized form")
end)

TestRunner:test("nil flag + effective on: parenthesized follows-default badge", function()
    local s = DT({ text = "A" }, IND, { effective_web_search = true })
    TestRunner:has(s, "(🌐)")
end)

TestRunner:test("quick_web_strip hides the badge ONLY for accepting actions", function()
    local accepting = DT({ text = "A", accept_quick_answer = true }, IND,
        { effective_web_search = true, quick_web_strip = true })
    TestRunner:hasnt(accepting, "🌐", "accepting action's send has web stripped at bake")
    local non_accepting = DT({ text = "A" }, IND,
        { effective_web_search = true, quick_web_strip = true })
    TestRunner:has(non_accepting, "(🌐)", "non-accepting actions ignore Quick and keep the badge")
end)

TestRunner:test("local-handler actions never carry a web badge (B340)", function()
    -- Generate Image and the X-Ray lookup send no search, whatever the global says
    local img = DT({ text = "Generate Image", local_handler = "image_gen" }, IND,
        { effective_web_search = true })
    TestRunner:hasnt(img, "🌐", "no follows-default badge on a local handler")
    TestRunner:eq(img, "Generate Image")
end)

TestRunner:test("smart retrieval badge only when tools could actually run", function()
    local off = DT({ text = "A", smart_retrieval = true }, IND, { tools_allowed = false })
    TestRunner:hasnt(off, "🔍")
    local on = DT({ text = "A", smart_retrieval = true }, IND, { tools_allowed = true })
    TestRunner:has(on, "(🔍)")
end)

print("")
print(string.rep("-", 50))
print(string.format("  Results: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
print(string.rep("-", 50))
return TestRunner.failed == 0
