--[[
Unit Tests for koassistant_reply_quote.lua

Covers the pure logic behind the chat viewer's "Add to reply" selection-popup
action (agenda 1c, chat_viewer_plan.md §2):
- quote-block formatting (append): fresh draft, existing draft, multi-line
  selections, whitespace trimming, blank-line separation
- eligibility gating: full chat viewer yes; simple_view / translate_view /
  minimal (compact/dictionary) / missing reply seam no

koassistant_chatgptviewer.lua itself can't be loaded under the harness (pulls
in the KOReader UI stack), so the bug-prone logic lives in the pure module and
is exercised here.

Run: lua tests/run_tests.lua --unit
]]

package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")

local ReplyQuote = require("koassistant_reply_quote")

local T = {
    passed = 0,
    failed = 0,
}

function T:test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  ✓ %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  ✗ %s: %s", name, tostring(err)))
    end
end

function T:assert(condition, message)
    if not condition then error(message or "Assertion failed", 2) end
end

function T:assertEquals(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s\n  expected: %q\n  actual:   %q",
            message or "Values differ", tostring(expected), tostring(actual)), 2)
    end
end

function T:runAll()
    print("\n  [ReplyQuote.append — quote-block formatting]")

    self:test("nil draft: quote block + trailing blank line", function()
        self:assertEquals(ReplyQuote.append(nil, "Hello world"), "> Hello world\n\n")
    end)

    self:test("empty draft treated like nil", function()
        self:assertEquals(ReplyQuote.append("", "Hello"), "> Hello\n\n")
    end)

    self:test("existing draft kept, separated by one blank line", function()
        self:assertEquals(ReplyQuote.append("my draft", "quoted bit"),
            "my draft\n\n> quoted bit\n\n")
    end)

    self:test("draft trailing whitespace collapsed to single blank line", function()
        self:assertEquals(ReplyQuote.append("my draft\n\n\n", "q"),
            "my draft\n\n> q\n\n")
    end)

    self:test("multi-line selection: every line quoted", function()
        self:assertEquals(ReplyQuote.append(nil, "line one\nline two"),
            "> line one\n> line two\n\n")
    end)

    self:test("blank inner line keeps quote-block continuity ('> ')", function()
        self:assertEquals(ReplyQuote.append(nil, "para one\n\npara two"),
            "> para one\n> \n> para two\n\n")
    end)

    self:test("selection trailing whitespace trimmed before quoting", function()
        self:assertEquals(ReplyQuote.append(nil, "trimmed   \n\n"), "> trimmed\n\n")
    end)

    self:test("whitespace-only selection: no bare quote marker, draft unchanged", function()
        self:assertEquals(ReplyQuote.append(nil, "  \n "), "")
        self:assertEquals(ReplyQuote.append("draft", "  \n "), "draft")
    end)

    self:test("second quote appends below the first", function()
        local d = ReplyQuote.append(nil, "first")
        self:assertEquals(ReplyQuote.append(d, "second"),
            "> first\n\n> second\n\n")
    end)

    print("\n  [ReplyQuote.eligible — popup gating]")

    local seam = function() end

    self:test("full chat viewer with reply seam → eligible", function()
        self:assert(ReplyQuote.eligible({ onAskQuestion = seam }) == true)
    end)

    self:test("simple_view (artifact) → not eligible", function()
        self:assert(ReplyQuote.eligible({ simple_view = true, onAskQuestion = seam }) == false)
    end)

    self:test("translate_view → not eligible", function()
        self:assert(ReplyQuote.eligible({ translate_view = true, onAskQuestion = seam }) == false)
    end)

    self:test("minimal_buttons (compact/dictionary) → not eligible", function()
        self:assert(ReplyQuote.eligible({ minimal_buttons = true, onAskQuestion = seam }) == false)
    end)

    self:test("no reply seam (tool-text viewer shape) → not eligible", function()
        self:assert(ReplyQuote.eligible({}) == false)
    end)

    self:test("nil viewer → not eligible", function()
        self:assert(ReplyQuote.eligible(nil) == false)
    end)

    print(string.format("\n  Results: %d passed, %d failed", self.passed, self.failed))
    return self.failed == 0
end

-- Run directly
if arg and arg[0] and arg[0]:match("test_reply_quote%.lua$") then
    local success = T:runAll()
    os.exit(success and 0 or 1)
end

return T
