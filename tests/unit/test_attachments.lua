--[[
Unit Tests for koassistant_attachments.lua (attach_plan.md v1)

Covers the pure attachment engine behind the Attach chip:
- budget truncation (head/tail keep, UTF-8 boundary safety, honest notes)
- staging list helpers (add/remove/count/clear, trusted-provider check)
- per-type builders: note, chat (skips is_context, role mapping), artifact
  (quiz refusal, empty refusal), pinned, file (partial read + real total)
- wire message framing (one framed section per attachment, notes included)

The UI side (chip, pickers) can't run under the harness; everything bug-prone
lives in the pure module and is exercised here.

Run: lua tests/run_tests.lua --unit
]]

package.path = package.path .. ";./?.lua;./?/init.lua"
require("tests.lib.mock_koreader")

local Attachments = require("koassistant_attachments")

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
        error(string.format("%s\n  expected: %s\n  actual:   %s",
            message or "Values not equal", tostring(expected), tostring(actual)), 2)
    end
end

function T:runAll()
    print("\ntest_attachments.lua")

    -- ------------------------------------------------------------ truncate ---

    self:test("truncate: under budget → unchanged, no note", function()
        local text, note = Attachments.truncate("short text", 100, "head")
        self:assertEquals(text, "short text")
        self:assert(note == nil, "no note expected")
    end)

    self:test("truncate head: keeps beginning, honest note", function()
        local long = string.rep("a", 500)
        local text, note = Attachments.truncate(long, 100, "head")
        self:assert(#text <= 100, "over budget")
        self:assertEquals(text:sub(1, 5), "aaaaa")
        self:assert(note and note:find("first", 1, true), "note should say 'first'")
        self:assert(note:find("500", 1, true), "note should carry the real total")
    end)

    self:test("truncate tail: keeps end, honest note", function()
        local long = string.rep("a", 400) .. "THE_END"
        local text, note = Attachments.truncate(long, 50, "tail")
        self:assert(text:sub(-7) == "THE_END", "tail not kept")
        self:assert(note and note:find("most recent", 1, true), "note should say 'most recent'")
    end)

    self:test("truncate head: no broken UTF-8 sequence at the cut", function()
        local long = string.rep("é", 300) -- 2 bytes each
        local text = Attachments.truncate(long, 101, "head") -- odd budget forces a mid-char cut
        self:assertEquals(#text % 2, 0, "cut split a multi-byte char")
        local last = text:byte(#text)
        self:assert(last >= 0x80, "expected multibyte tail")
    end)

    self:test("truncate tail: no leading continuation bytes", function()
        local long = string.rep("é", 300)
        local text = Attachments.truncate(long, 101, "tail")
        local first = text:byte(1)
        self:assert(first < 0x80 or first >= 0xC0, "starts mid-sequence")
    end)

    self:test("truncate: malformed input (continuation-byte runs) stays bounded", function()
        -- Binary/corrupt input must pass through with bounded work, not trigger
        -- unbounded rescans (2026-07-17 review gate finding)
        local garbage = string.rep(string.char(0xAA), 5000)
        local text = Attachments.truncate(garbage, 100, "head")
        self:assert(#text <= 100, "over budget on malformed input")
        local tail_text = Attachments.truncate(garbage, 100, "tail")
        self:assert(#tail_text <= 100, "tail over budget on malformed input")
    end)

    self:test("truncate head: prefers cutting at a near line break", function()
        local long = string.rep("x", 90) .. "\n" .. string.rep("y", 200)
        local text = Attachments.truncate(long, 100, "head")
        self:assertEquals(#text, 90, "should cut at the line break")
    end)

    -- ------------------------------------------------------------- staging ---

    self:test("add/count/remove/clear lifecycle (module-resident)", function()
        Attachments.clear()
        self:assertEquals(Attachments.count(), 0)
        self:assert(Attachments.getList() == nil, "empty list reads as nil")
        Attachments.add({ type = "note", label = "a", text = "a" })
        Attachments.add({ type = "note", label = "b", text = "b" })
        self:assertEquals(Attachments.count(), 2)
        Attachments.remove(1)
        self:assertEquals(Attachments.count(), 1)
        self:assertEquals(Attachments.getList()[1].label, "b")
        Attachments.remove(1)
        self:assert(Attachments.getList() == nil, "empty list reads as nil again")
        Attachments.add({ type = "note", label = "c", text = "c" })
        Attachments.clear()
        self:assert(Attachments.getList() == nil and Attachments.count() == 0,
            "clear should empty the staging list")
    end)

    self:test("isTrustedProvider matches the configured list", function()
        local features = { trusted_providers = { "ollama", "anthropic" } }
        self:assert(Attachments.isTrustedProvider(features, "anthropic"))
        self:assert(not Attachments.isTrustedProvider(features, "openai"))
        self:assert(not Attachments.isTrustedProvider({}, "anthropic"))
        self:assert(not Attachments.isTrustedProvider(nil, "anthropic"))
    end)

    -- ---------------------------------------------------------------- note ---

    self:test("makeNote: rejects empty/whitespace", function()
        local entry, err = Attachments.makeNote("   \n  ")
        self:assert(entry == nil and err ~= nil, "should refuse blank note")
    end)

    self:test("makeNote: label is first line, capped", function()
        local entry = Attachments.makeNote("This is the first line\nsecond line")
        self:assertEquals(entry.type, "note")
        self:assertEquals(entry.label, "This is the first line")
        local long_line = string.rep("w", 80)
        local entry2 = Attachments.makeNote(long_line)
        self:assert(#entry2.label <= 43, "label not capped") -- 40 + ellipsis bytes
    end)

    -- ---------------------------------------------------------------- chat ---

    self:test("makeChat: skips is_context, maps roles", function()
        local chat = {
            title = "My chat",
            messages = {
                { role = "user", content = "HUGE CONTEXT DUMP", is_context = true },
                { role = "user", content = "What is this book about?" },
                { role = "assistant", content = "It is about whales." },
            },
        }
        local entry = Attachments.makeChat(chat, "Moby-Dick")
        self:assert(entry, "entry expected")
        self:assert(not entry.text:find("HUGE CONTEXT DUMP", 1, true), "context message leaked")
        self:assert(entry.text:find("Reader: What is this book about?", 1, true), "user turn missing")
        self:assert(entry.text:find("Assistant: It is about whales.", 1, true), "assistant turn missing")
        self:assertEquals(entry.title, "My chat")
        self:assertEquals(entry.book_title, "Moby-Dick")
    end)

    self:test("makeChat: only-context chat refused", function()
        local entry, err = Attachments.makeChat({ messages = {
            { role = "user", content = "ctx", is_context = true },
        } })
        self:assert(entry == nil and err ~= nil)
    end)

    self:test("makeChat: truncation keeps the tail (conclusions)", function()
        local messages = {}
        for i = 1, 400 do
            table.insert(messages, { role = "user", content = "turn number " .. i .. " " .. string.rep("pad", 30) })
        end
        local entry = Attachments.makeChat({ title = "long", messages = messages })
        self:assert(entry.note, "expected truncation note")
        self:assert(entry.text:find("turn number 400", 1, true), "latest turn should survive")
        self:assert(not entry.text:find("turn number 1 ", 1, true), "earliest turn should be dropped")
    end)

    -- ------------------------------------------------------------ artifact ---

    self:test("makeArtifact: quiz keys refused (real ActionCache identifiers)", function()
        -- Authoritative literals: ARTIFACT_KEYS "quiz", SECTION_PREFIXES.quiz
        -- "quiz_section:" — NOT the action id "generate_quiz" (caught by the
        -- 2026-07-17 review gate: the first cut matched the wrong literal)
        local entry, err = Attachments.makeArtifact("Quiz", "quiz", { result = "{}" })
        self:assert(entry == nil and err ~= nil, "per-action quiz should be refused")
        local entry2, err2 = Attachments.makeArtifact("Section", "quiz_section:abc123", { result = "{}" })
        self:assert(entry2 == nil and err2 ~= nil, "section-quiz key prefix should be refused")
        local entry3, err3 = Attachments.makeArtifact("Section", "some_key", { result = "{}" }, nil, "quiz")
        self:assert(entry3 == nil and err3 ~= nil, "section_type quiz should be refused")
        -- Non-quiz keys must NOT be refused by the quiz guard
        local ok_entry = Attachments.makeArtifact("Summary", "summarize", { result = "plain text" })
        self:assert(ok_entry ~= nil, "non-quiz artifact should pass")
    end)

    self:test("makeArtifact: empty result refused, plain result attached", function()
        local none, err = Attachments.makeArtifact("Summary", "summarize", { result = "" })
        self:assert(none == nil and err ~= nil)
        local entry = Attachments.makeArtifact("Summary", "summarize", { result = "A fine summary." }, "Moby-Dick")
        self:assertEquals(entry.type, "artifact")
        self:assertEquals(entry.name, "Summary")
        self:assertEquals(entry.book_title, "Moby-Dick")
        self:assertEquals(entry.text, "A fine summary.")
    end)

    self:test("makePinned: uses pin result and name", function()
        local entry = Attachments.makePinned({
            name = "Key ideas", result = "Pinned content.", book_title = "Moby-Dick",
        })
        self:assertEquals(entry.type, "artifact")
        self:assertEquals(entry.name, "Key ideas")
        self:assertEquals(entry.text, "Pinned content.")
        local none, err = Attachments.makePinned({ name = "empty" })
        self:assert(none == nil and err ~= nil)
    end)

    -- ---------------------------------------------------------------- file ---

    self:test("makeFile: reads content, refuses missing/empty", function()
        local path = os.tmpname()
        local f = io.open(path, "w")
        f:write("File body line 1\nline 2")
        f:close()
        local entry = Attachments.makeFile(path)
        self:assert(entry, "entry expected")
        self:assertEquals(entry.type, "file")
        self:assertEquals(entry.filename, path:match("([^/]+)$"))
        self:assert(entry.text:find("File body line 1", 1, true))
        os.remove(path)
        local none, err = Attachments.makeFile(path)
        self:assert(none == nil and err ~= nil, "missing file should refuse")
    end)

    self:test("makeFile: partial read reports the real file size", function()
        local path = os.tmpname()
        local f = io.open(path, "w")
        f:write(string.rep("z", Attachments.BUDGETS.file + 5000))
        f:close()
        local entry = Attachments.makeFile(path)
        os.remove(path)
        self:assert(#entry.text <= Attachments.BUDGETS.file, "over budget")
        self:assert(entry.note and entry.note:find(tostring(Attachments.BUDGETS.file + 5000), 1, true),
            "note should carry the real total size")
    end)

    -- ---------------------------------------------------------------- wire ---

    self:test("buildMessage: nil for empty", function()
        self:assert(Attachments.buildMessage(nil) == nil)
        self:assert(Attachments.buildMessage({}) == nil)
    end)

    self:test("buildMessage: one framed section per attachment", function()
        local msg = Attachments.buildMessage({
            { type = "notebook", label = "nb", text = "my notes" },
            { type = "artifact", name = "Summary", book_title = "Moby-Dick", label = "Summary", text = "sum" },
            { type = "chat", title = "Old chat", label = "Old chat", text = "Reader: hi" },
            { type = "file", filename = "notes.md", label = "notes.md", text = "file body" },
            { type = "note", label = "n", text = "remember this" },
        })
        self:assert(msg:find("[Attached: the reader's own notebook for this book]", 1, true), "notebook frame")
        self:assert(msg:find('[Attached: a saved AI artifact — "Summary" (about "Moby-Dick")]', 1, true), "artifact frame")
        self:assert(msg:find('conversation between the reader and the assistant — "Old chat"', 1, true), "chat frame")
        self:assert(msg:find("[Attached file: notes.md]", 1, true), "file frame")
        self:assert(msg:find("[Note from the reader]", 1, true), "note frame")
        self:assert(msg:find("remember this", 1, true), "note body")
    end)

    self:test("buildMessage: truncation note rides inside the section", function()
        local msg = Attachments.buildMessage({
            { type = "note", label = "n", text = "body", note = "[Attachment truncated: showing the first 4 of 9 characters]" },
        })
        self:assert(msg:find("[Attachment truncated:", 1, true), "note missing")
    end)

    print(string.format("\n  Results: %d passed, %d failed", self.passed, self.failed))
    return self.failed == 0
end

-- Run directly
if arg and arg[0] and arg[0]:match("test_attachments%.lua$") then
    local success = T:runAll()
    os.exit(success and 0 or 1)
end

return T
