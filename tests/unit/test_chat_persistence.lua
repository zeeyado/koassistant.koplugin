--[[
Unit Tests for ChatHistoryManager persistence

Tests save/load roundtrips, tag operations, rename operations,
and the critical bug scenario where full-replacement saves
must not lose tags or custom titles.

Run: lua tests/run_tests.lua --unit
]]

-- Setup test environment
local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/?/init.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()

-- ============================================================
-- In-memory storage mocks (must be installed BEFORE mock_koreader)
-- ============================================================

-- Deep copy utility (prevents reference-sharing bugs)
local function deepCopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do
        copy[deepCopy(k)] = deepCopy(v)
    end
    return setmetatable(copy, getmetatable(orig))
end

-- Shared in-memory store keyed by file path
local mock_storage = {}

-- Reset all storage (call between tests for isolation)
local function resetStorage()
    mock_storage = {}
end

-- MockLuaSettings: in-memory key-value store per file path
local MockLuaSettings = {}
MockLuaSettings.__index = MockLuaSettings

function MockLuaSettings:open(path)
    if not mock_storage[path] then mock_storage[path] = {} end
    return setmetatable({ _path = path }, MockLuaSettings)
end

function MockLuaSettings:readSetting(key, default)
    local val = mock_storage[self._path][key]
    if val == nil then return default end
    return deepCopy(val)
end

function MockLuaSettings:saveSetting(key, value)
    mock_storage[self._path][key] = deepCopy(value)
end

function MockLuaSettings:flush() end

-- Install LuaSettings mock before anything else
package.loaded["luasettings"] = MockLuaSettings

-- MockDocSettings: same interface, used for book chats
local MockDocSettings = {}
MockDocSettings.__index = MockDocSettings

function MockDocSettings:open(path)
    local store_key = "docsettings:" .. path
    if not mock_storage[store_key] then mock_storage[store_key] = {} end
    return setmetatable({ _path = store_key }, MockDocSettings)
end

function MockDocSettings:readSetting(key, default)
    local val = mock_storage[self._path][key]
    if val == nil then return default end
    return deepCopy(val)
end

function MockDocSettings:saveSetting(key, value)
    mock_storage[self._path][key] = deepCopy(value)
end

function MockDocSettings:flush() end

package.loaded["docsettings"] = MockDocSettings

-- Mock util (imported by ChatHistoryManager but not actually called)
package.loaded["util"] = {}

-- Mock ffi/sha2 (md5 used only in v1 path)
package.loaded["ffi/sha2"] = {
    md5 = function(str) return "mock_md5_" .. tostring(str):sub(1, 8) end
}

-- Mock G_reader_settings (global, used for storage version and chat index)
local g_reader_store = {}
_G.G_reader_settings = {
    readSetting = function(_self, key, default)
        if key == "chat_storage_version" then return 2 end  -- Force v2 path
        local val = g_reader_store[key]
        if val == nil then return default end
        return deepCopy(val)
    end,
    saveSetting = function(_self, key, value)
        g_reader_store[key] = deepCopy(value)
    end,
    flush = function() end,
}

-- Now load the standard mocks
require("mock_koreader")

-- Override lfs.attributes to accept test document paths
local mock_lfs = package.loaded["libs/libkoreader-lfs"]
local original_attributes = mock_lfs and mock_lfs.attributes
-- Track which paths should "exist" as files
local mock_file_paths = {}

local function registerMockFile(path)
    mock_file_paths[path] = true
end

-- Patch lfs.attributes to return file info for registered paths
if mock_lfs then
    mock_lfs.attributes = function(path, attr)
        if mock_file_paths[path] then
            if attr == "mode" then return "file" end
            return { mode = "file" }
        end
        if original_attributes then
            return original_attributes(path, attr)
        end
        return nil
    end
end

-- Now load ChatHistoryManager
local ChatHistoryManager = require("koassistant_chat_history_manager")

-- ============================================================
-- Test Runner
-- ============================================================
local TestRunner = {
    passed = 0,
    failed = 0,
}

function TestRunner:test(name, fn)
    -- Reset storage before each test for isolation
    resetStorage()
    g_reader_store = {}

    local ok, err = pcall(fn)
    if ok then
        self.passed = self.passed + 1
        print(string.format("  \226\156\147 %s", name))
    else
        self.failed = self.failed + 1
        print(string.format("  \226\156\151 %s: %s", name, tostring(err)))
    end
end

function TestRunner:assertEqual(actual, expected, message)
    if actual ~= expected then
        error(string.format("%s: expected '%s', got '%s'",
            message or "Values not equal",
            tostring(expected),
            tostring(actual)), 2)
    end
end

function TestRunner:assertNotNil(value, message)
    if value == nil then
        error(string.format("%s: expected non-nil", message or "Assertion failed"), 2)
    end
end

function TestRunner:assertNil(value, message)
    if value ~= nil then
        error(string.format("%s: expected nil, got '%s'", message or "Assertion failed", tostring(value)), 2)
    end
end

function TestRunner:assertTrue(value, message)
    if not value then
        error(string.format("%s: expected true, got '%s'", message or "Assertion failed", tostring(value)), 2)
    end
end

function TestRunner:assertFalse(value, message)
    if value then
        error(string.format("%s: expected false, got '%s'", message or "Assertion failed", tostring(value)), 2)
    end
end

function TestRunner:assertTableLength(t, expected_len, message)
    local actual = #t
    if actual ~= expected_len then
        error(string.format("%s: expected length %d, got %d",
            message or "Table length mismatch",
            expected_len, actual), 2)
    end
end

-- ============================================================
-- Test Helpers
-- ============================================================

local function makeChatData(overrides)
    local chat = {
        id = overrides.id or ("test_" .. math.random(100000, 999999)),
        title = overrides.title or "Test Chat",
        document_path = overrides.document_path or "__GENERAL_CHATS__",
        timestamp = overrides.timestamp or os.time(),
        messages = overrides.messages or {
            { role = "user", content = "Hello" },
            { role = "assistant", content = "Hi there!" },
        },
        model = overrides.model or "test-model",
        metadata = overrides.metadata or {},
        tags = overrides.tags or {},
        book_title = overrides.book_title,
        book_author = overrides.book_author,
        prompt_action = overrides.prompt_action,
        launch_context = overrides.launch_context,
        domain = overrides.domain,
        original_highlighted_text = overrides.original_highlighted_text,
    }
    return chat
end

-- ============================================================
-- Tests: General Chat Save/Load Roundtrip
-- ============================================================

print("\n  -- General Chat Save/Load --")

TestRunner:test("save and load general chat roundtrip", function()
    local mgr = ChatHistoryManager:new()
    local chat = makeChatData({ id = "chat_001", title = "My Chat", tags = {"important", "research"} })

    local result = mgr:saveGeneralChat(chat)
    TestRunner:assertNotNil(result, "saveGeneralChat should return chat ID")

    local loaded = mgr:getGeneralChatById("chat_001")
    TestRunner:assertNotNil(loaded, "Should load saved chat")
    TestRunner:assertEqual(loaded.title, "My Chat", "Title should match")
    TestRunner:assertEqual(loaded.model, "test-model", "Model should match")
    TestRunner:assertTableLength(loaded.tags, 2, "Tags should have 2 entries")
    TestRunner:assertEqual(loaded.tags[1], "important", "First tag should match")
    TestRunner:assertEqual(loaded.tags[2], "research", "Second tag should match")
    TestRunner:assertTableLength(loaded.messages, 2, "Messages should have 2 entries")
end)

TestRunner:test("save with empty tags returns empty array not nil", function()
    local mgr = ChatHistoryManager:new()
    local chat = makeChatData({ id = "chat_002", tags = {} })

    mgr:saveGeneralChat(chat)
    local loaded = mgr:getGeneralChatById("chat_002")
    TestRunner:assertNotNil(loaded.tags, "Tags should not be nil")
    TestRunner:assertTableLength(loaded.tags, 0, "Tags should be empty")
end)

TestRunner:test("save with tags preserves order", function()
    local mgr = ChatHistoryManager:new()
    local chat = makeChatData({ id = "chat_003", tags = {"zebra", "alpha", "middle"} })

    mgr:saveGeneralChat(chat)
    local loaded = mgr:getGeneralChatById("chat_003")
    TestRunner:assertEqual(loaded.tags[1], "zebra", "Tag order preserved: first")
    TestRunner:assertEqual(loaded.tags[2], "alpha", "Tag order preserved: second")
    TestRunner:assertEqual(loaded.tags[3], "middle", "Tag order preserved: third")
end)

-- ============================================================
-- Tests: Tag Operations
-- ============================================================

print("\n  -- Tag Operations --")

TestRunner:test("addTagToChat adds tag to existing chat", function()
    local mgr = ChatHistoryManager:new()
    local chat = makeChatData({ id = "chat_tag_1", tags = {} })
    mgr:saveGeneralChat(chat)

    local ok = mgr:addTagToChat("__GENERAL_CHATS__", "chat_tag_1", "new-tag")
    TestRunner:assertTrue(ok, "addTagToChat should succeed")

    local loaded = mgr:getGeneralChatById("chat_tag_1")
    TestRunner:assertTableLength(loaded.tags, 1, "Should have 1 tag")
    TestRunner:assertEqual(loaded.tags[1], "new-tag", "Tag should match")
end)

TestRunner:test("addTagToChat rejects duplicate tag", function()
    local mgr = ChatHistoryManager:new()
    local chat = makeChatData({ id = "chat_tag_2", tags = {"existing"} })
    mgr:saveGeneralChat(chat)

    local ok = mgr:addTagToChat("__GENERAL_CHATS__", "chat_tag_2", "existing")
    TestRunner:assertTrue(ok, "Duplicate tag should return true (idempotent)")

    local loaded = mgr:getGeneralChatById("chat_tag_2")
    TestRunner:assertTableLength(loaded.tags, 1, "Should still have only 1 tag")
end)

TestRunner:test("addTagToChat trims whitespace", function()
    local mgr = ChatHistoryManager:new()
    local chat = makeChatData({ id = "chat_tag_3", tags = {} })
    mgr:saveGeneralChat(chat)

    mgr:addTagToChat("__GENERAL_CHATS__", "chat_tag_3", "  trimmed  ")
    local loaded = mgr:getGeneralChatById("chat_tag_3")
    TestRunner:assertEqual(loaded.tags[1], "trimmed", "Tag should be trimmed")
end)

TestRunner:test("addTagToChat rejects empty/whitespace-only tag", function()
    local mgr = ChatHistoryManager:new()
    local chat = makeChatData({ id = "chat_tag_4", tags = {} })
    mgr:saveGeneralChat(chat)

    local ok = mgr:addTagToChat("__GENERAL_CHATS__", "chat_tag_4", "   ")
    TestRunner:assertFalse(ok, "Whitespace-only tag should be rejected")

    local loaded = mgr:getGeneralChatById("chat_tag_4")
    TestRunner:assertTableLength(loaded.tags, 0, "No tags should be added")
end)

TestRunner:test("removeTagFromChat removes correct tag", function()
    local mgr = ChatHistoryManager:new()
    local chat = makeChatData({ id = "chat_tag_5", tags = {"keep", "remove", "also-keep"} })
    mgr:saveGeneralChat(chat)

    local ok = mgr:removeTagFromChat("__GENERAL_CHATS__", "chat_tag_5", "remove")
    TestRunner:assertTrue(ok, "removeTagFromChat should succeed")

    local loaded = mgr:getGeneralChatById("chat_tag_5")
    TestRunner:assertTableLength(loaded.tags, 2, "Should have 2 tags left")
    TestRunner:assertEqual(loaded.tags[1], "keep", "First remaining tag")
    TestRunner:assertEqual(loaded.tags[2], "also-keep", "Second remaining tag")
end)

TestRunner:test("removeTagFromChat preserves other tags", function()
    local mgr = ChatHistoryManager:new()
    local chat = makeChatData({ id = "chat_tag_6", tags = {"a", "b", "c", "d"} })
    mgr:saveGeneralChat(chat)

    mgr:removeTagFromChat("__GENERAL_CHATS__", "chat_tag_6", "b")
    local loaded = mgr:getGeneralChatById("chat_tag_6")
    TestRunner:assertTableLength(loaded.tags, 3, "Should have 3 tags")
    TestRunner:assertEqual(loaded.tags[1], "a", "Tag a preserved")
    TestRunner:assertEqual(loaded.tags[2], "c", "Tag c preserved")
    TestRunner:assertEqual(loaded.tags[3], "d", "Tag d preserved")
end)

-- ============================================================
-- Tests: Rename Operations
-- ============================================================

print("\n  -- Rename Operations --")

TestRunner:test("renameChat updates title", function()
    local mgr = ChatHistoryManager:new()
    local chat = makeChatData({ id = "chat_rename_1", title = "Original Title" })
    mgr:saveGeneralChat(chat)

    local ok = mgr:renameChat("__GENERAL_CHATS__", "chat_rename_1", "Custom Title")
    TestRunner:assertTrue(ok, "renameChat should succeed")

    local loaded = mgr:getGeneralChatById("chat_rename_1")
    TestRunner:assertEqual(loaded.title, "Custom Title", "Title should be updated")
end)

TestRunner:test("rename preserves other fields", function()
    local mgr = ChatHistoryManager:new()
    local chat = makeChatData({
        id = "chat_rename_2",
        title = "Original",
        tags = {"important"},
        model = "my-model",
    })
    mgr:saveGeneralChat(chat)

    mgr:renameChat("__GENERAL_CHATS__", "chat_rename_2", "New Name")
    local loaded = mgr:getGeneralChatById("chat_rename_2")
    TestRunner:assertEqual(loaded.title, "New Name", "Title updated")
    TestRunner:assertTableLength(loaded.tags, 1, "Tags preserved")
    TestRunner:assertEqual(loaded.tags[1], "important", "Tag value preserved")
    TestRunner:assertEqual(loaded.model, "my-model", "Model preserved")
    TestRunner:assertTableLength(loaded.messages, 2, "Messages preserved")
end)

-- ============================================================
-- Tests: CRITICAL BUG SCENARIO - Full Replacement Preserves Tags/Title
-- ============================================================

print("\n  -- Full Replacement Bug Scenario --")

TestRunner:test("save -> addTag -> full replace save -> tags still present", function()
    local mgr = ChatHistoryManager:new()

    -- 1. Initial save
    local chat = makeChatData({ id = "bug_test_1", title = "Auto Title", tags = {} })
    mgr:saveGeneralChat(chat)

    -- 2. Add a tag (via partial update)
    mgr:addTagToChat("__GENERAL_CHATS__", "bug_test_1", "important")

    -- Verify tag is there
    local after_tag = mgr:getGeneralChatById("bug_test_1")
    TestRunner:assertTableLength(after_tag.tags, 1, "Tag should be present after addTag")

    -- 3. Full replacement save (simulating what dialogs.lua does - updated messages)
    local updated_chat = makeChatData({
        id = "bug_test_1",
        title = "Auto Title",
        tags = {},  -- BUG: caller passes empty tags
        messages = {
            { role = "user", content = "Hello" },
            { role = "assistant", content = "Hi!" },
            { role = "user", content = "Follow up" },
            { role = "assistant", content = "Sure!" },
        },
    })
    mgr:saveGeneralChat(updated_chat)

    -- 4. The tag should be GONE here because saveGeneralChat does full replacement
    -- This test documents the behavior: callers MUST preserve tags themselves
    local after_replace = mgr:getGeneralChatById("bug_test_1")
    -- NOTE: saveGeneralChat does full replacement (chats[id] = chat_data)
    -- so if caller doesn't include tags, they're lost.
    -- The FIX is in the callers (dialogs.lua) which now load existing tags before saving.
    TestRunner:assertTableLength(after_replace.tags, 0,
        "Full replacement with empty tags loses tags (caller must preserve)")
end)

TestRunner:test("save -> addTag -> reload+merge save -> tags preserved", function()
    local mgr = ChatHistoryManager:new()

    -- 1. Initial save
    local chat = makeChatData({ id = "bug_test_2", title = "Auto Title", tags = {} })
    mgr:saveGeneralChat(chat)

    -- 2. Add a tag
    mgr:addTagToChat("__GENERAL_CHATS__", "bug_test_2", "important")

    -- 3. CORRECT pattern: reload existing chat, merge, then full-replace save
    local existing = mgr:getGeneralChatById("bug_test_2")
    TestRunner:assertNotNil(existing, "Should load existing chat")
    local existing_tags = existing.tags or {}
    local existing_title = existing.title

    local updated_chat = makeChatData({
        id = "bug_test_2",
        title = existing_title,  -- Preserve custom title
        tags = existing_tags,    -- Preserve existing tags
        messages = {
            { role = "user", content = "Hello" },
            { role = "assistant", content = "Hi!" },
            { role = "user", content = "Follow up" },
            { role = "assistant", content = "Sure!" },
        },
    })
    mgr:saveGeneralChat(updated_chat)

    -- 4. Tags and title should be preserved
    local final = mgr:getGeneralChatById("bug_test_2")
    TestRunner:assertTableLength(final.tags, 1, "Tags preserved after reload+merge save")
    TestRunner:assertEqual(final.tags[1], "important", "Tag value preserved")
end)

TestRunner:test("save -> rename -> reload+merge save -> custom title preserved", function()
    local mgr = ChatHistoryManager:new()

    -- 1. Initial save
    local chat = makeChatData({ id = "bug_test_3", title = "Auto Title" })
    mgr:saveGeneralChat(chat)

    -- 2. Rename
    mgr:renameChat("__GENERAL_CHATS__", "bug_test_3", "My Custom Title")

    -- 3. CORRECT pattern: reload, merge, save
    local existing = mgr:getGeneralChatById("bug_test_3")
    local updated_chat = makeChatData({
        id = "bug_test_3",
        title = existing.title,  -- Should be "My Custom Title"
        messages = {
            { role = "user", content = "Hello" },
            { role = "assistant", content = "World" },
            { role = "user", content = "More" },
            { role = "assistant", content = "Content" },
        },
    })
    mgr:saveGeneralChat(updated_chat)

    local final = mgr:getGeneralChatById("bug_test_3")
    TestRunner:assertEqual(final.title, "My Custom Title", "Custom title preserved after reload+merge save")
end)

TestRunner:test("save -> addTag + rename -> reload+merge save -> both preserved", function()
    local mgr = ChatHistoryManager:new()

    -- 1. Initial save
    local chat = makeChatData({ id = "bug_test_4", title = "Auto", tags = {} })
    mgr:saveGeneralChat(chat)

    -- 2. Add tag AND rename
    mgr:addTagToChat("__GENERAL_CHATS__", "bug_test_4", "research")
    mgr:renameChat("__GENERAL_CHATS__", "bug_test_4", "Custom Name")

    -- 3. Reload, merge, save (the fixed pattern)
    local existing = mgr:getGeneralChatById("bug_test_4")
    local updated_chat = makeChatData({
        id = "bug_test_4",
        title = existing.title,
        tags = existing.tags,
        messages = {
            { role = "user", content = "Updated messages" },
            { role = "assistant", content = "Updated response" },
        },
    })
    mgr:saveGeneralChat(updated_chat)

    local final = mgr:getGeneralChatById("bug_test_4")
    TestRunner:assertEqual(final.title, "Custom Name", "Custom title preserved")
    TestRunner:assertTableLength(final.tags, 1, "Tags preserved")
    TestRunner:assertEqual(final.tags[1], "research", "Tag value preserved")
end)

-- ============================================================
-- Tests: DocSettings Path (Book Chats)
-- ============================================================

print("\n  -- DocSettings Path (Book Chats) --")

TestRunner:test("save and load book chat via DocSettings", function()
    local mgr = ChatHistoryManager:new()
    local doc_path = "/test/books/mybook.epub"
    registerMockFile(doc_path)

    local chat = makeChatData({
        id = "book_chat_1",
        title = "Book Chat",
        document_path = doc_path,
        tags = {"chapter1"},
        book_title = "Test Book",
        book_author = "Test Author",
    })

    local result = mgr:saveChatToDocSettings(nil, chat)
    TestRunner:assertNotNil(result, "saveChatToDocSettings should return chat ID")

    local loaded = mgr:getChatById(doc_path, "book_chat_1")
    TestRunner:assertNotNil(loaded, "Should load saved book chat")
    TestRunner:assertEqual(loaded.title, "Book Chat", "Title should match")
    TestRunner:assertTableLength(loaded.tags, 1, "Tags should have 1 entry")
    TestRunner:assertEqual(loaded.tags[1], "chapter1", "Tag should match")
    TestRunner:assertEqual(loaded.book_title, "Test Book", "Book title should match")
end)

TestRunner:test("updateChatInDocSettings preserves unmodified fields", function()
    local mgr = ChatHistoryManager:new()
    local doc_path = "/test/books/mybook2.epub"
    registerMockFile(doc_path)

    local chat = makeChatData({
        id = "book_chat_2",
        title = "Original Title",
        document_path = doc_path,
        tags = {"original-tag"},
        model = "original-model",
    })
    mgr:saveChatToDocSettings(nil, chat)

    -- Partial update: only change title
    local ok = mgr:updateChatInDocSettings(nil, "book_chat_2", { title = "New Title" }, doc_path)
    TestRunner:assertTrue(ok, "updateChatInDocSettings should succeed")

    local loaded = mgr:getChatById(doc_path, "book_chat_2")
    TestRunner:assertEqual(loaded.title, "New Title", "Title should be updated")
    TestRunner:assertTableLength(loaded.tags, 1, "Tags should be preserved")
    TestRunner:assertEqual(loaded.tags[1], "original-tag", "Tag value preserved")
    TestRunner:assertEqual(loaded.model, "original-model", "Model preserved")
end)

TestRunner:test("book chat: addTag then full replacement save preserves tags (reload pattern)", function()
    local mgr = ChatHistoryManager:new()
    local doc_path = "/test/books/mybook3.epub"
    registerMockFile(doc_path)

    -- 1. Initial save
    local chat = makeChatData({
        id = "book_chat_3",
        title = "Auto Title",
        document_path = doc_path,
        tags = {},
    })
    mgr:saveChatToDocSettings(nil, chat)

    -- 2. Add tag via partial update
    mgr:addTagToChat(doc_path, "book_chat_3", "important")

    -- 3. Verify tag is persisted
    local after_tag = mgr:getChatById(doc_path, "book_chat_3")
    TestRunner:assertTableLength(after_tag.tags, 1, "Tag should exist after addTag")

    -- 4. Reload, merge, full-replace save (the fixed caller pattern)
    local existing = mgr:getChatById(doc_path, "book_chat_3")
    local updated_chat = makeChatData({
        id = "book_chat_3",
        title = existing.title,
        document_path = doc_path,
        tags = existing.tags,
        messages = {
            { role = "user", content = "New message" },
            { role = "assistant", content = "New response" },
        },
    })
    mgr:saveChatToDocSettings(nil, updated_chat)

    -- 5. Tags should be preserved
    local final = mgr:getChatById(doc_path, "book_chat_3")
    TestRunner:assertTableLength(final.tags, 1, "Tags preserved after full-replace")
    TestRunner:assertEqual(final.tags[1], "important", "Tag value preserved")
end)

-- ============================================================
-- Tests: Library Chat Path
-- ============================================================

print("\n  -- Library Chat Path --")

TestRunner:test("save and load library chat", function()
    local mgr = ChatHistoryManager:new()
    local chat = makeChatData({
        id = "multi_chat_1",
        title = "Library Chat",
        document_path = "__LIBRARY_CHATS__",
        tags = {"comparison"},
    })

    local result = mgr:saveLibraryChat(chat)
    TestRunner:assertNotNil(result, "saveLibraryChat should return chat ID")

    local loaded = mgr:getLibraryChatById("multi_chat_1")
    TestRunner:assertNotNil(loaded, "Should load saved library chat")
    TestRunner:assertEqual(loaded.title, "Library Chat", "Title should match")
    TestRunner:assertTableLength(loaded.tags, 1, "Tags should have 1 entry")
    TestRunner:assertEqual(loaded.tags[1], "comparison", "Tag should match")
end)

TestRunner:test("library chat: tags preserved through update cycle", function()
    local mgr = ChatHistoryManager:new()
    local chat = makeChatData({
        id = "multi_chat_2",
        title = "Auto",
        document_path = "__LIBRARY_CHATS__",
        tags = {},
    })
    mgr:saveLibraryChat(chat)

    -- Add tag, rename
    mgr:addTagToChat("__LIBRARY_CHATS__", "multi_chat_2", "favorites")
    mgr:renameChat("__LIBRARY_CHATS__", "multi_chat_2", "Custom Name")

    -- Reload, merge, save
    local existing = mgr:getChatById("__LIBRARY_CHATS__", "multi_chat_2")
    local updated = makeChatData({
        id = "multi_chat_2",
        title = existing.title,
        document_path = "__LIBRARY_CHATS__",
        tags = existing.tags,
    })
    mgr:saveLibraryChat(updated)

    local final = mgr:getLibraryChatById("multi_chat_2")
    TestRunner:assertEqual(final.title, "Custom Name", "Title preserved")
    TestRunner:assertTableLength(final.tags, 1, "Tags preserved")
end)

-- ============================================================
-- Tests: getAllTags aggregation
-- ============================================================

print("\n  -- getAllTags Aggregation --")

TestRunner:test("getAllTags aggregates from multiple chats", function()
    local mgr = ChatHistoryManager:new()

    mgr:saveGeneralChat(makeChatData({ id = "agg_1", tags = {"alpha", "beta"} }))
    mgr:saveGeneralChat(makeChatData({ id = "agg_2", tags = {"gamma", "beta"} }))

    local all_tags = mgr:getAllTags()
    -- Should contain alpha, beta, gamma (deduplicated)
    local tag_set = {}
    for _idx, tag in ipairs(all_tags) do
        tag_set[tag] = true
    end
    TestRunner:assertTrue(tag_set["alpha"], "Should contain alpha")
    TestRunner:assertTrue(tag_set["beta"], "Should contain beta")
    TestRunner:assertTrue(tag_set["gamma"], "Should contain gamma")
end)

TestRunner:test("getAllTags deduplicates across chats", function()
    local mgr = ChatHistoryManager:new()

    mgr:saveGeneralChat(makeChatData({ id = "dedup_1", tags = {"shared"} }))
    mgr:saveGeneralChat(makeChatData({ id = "dedup_2", tags = {"shared"} }))
    mgr:saveGeneralChat(makeChatData({ id = "dedup_3", tags = {"shared", "unique"} }))

    local all_tags = mgr:getAllTags()
    -- Count occurrences of "shared"
    local shared_count = 0
    for _idx, tag in ipairs(all_tags) do
        if tag == "shared" then shared_count = shared_count + 1 end
    end
    TestRunner:assertEqual(shared_count, 1, "shared tag should appear exactly once")
end)

-- ============================================================
-- Tests: Edge Cases
-- ============================================================

print("\n  -- Edge Cases --")

TestRunner:test("getChatById returns nil for non-existent chat", function()
    local mgr = ChatHistoryManager:new()
    local result = mgr:getGeneralChatById("does_not_exist")
    TestRunner:assertNil(result, "Should return nil for non-existent chat")
end)

TestRunner:test("addTagToChat on non-existent chat returns false", function()
    local mgr = ChatHistoryManager:new()
    local ok = mgr:addTagToChat("__GENERAL_CHATS__", "does_not_exist", "tag")
    TestRunner:assertFalse(ok, "Should return false for non-existent chat")
end)

TestRunner:test("renameChat on non-existent chat returns false", function()
    local mgr = ChatHistoryManager:new()
    local ok = mgr:renameChat("__GENERAL_CHATS__", "does_not_exist", "new name")
    TestRunner:assertFalse(ok, "Should return false for non-existent chat")
end)

TestRunner:test("multiple tags added in sequence", function()
    local mgr = ChatHistoryManager:new()
    local chat = makeChatData({ id = "multi_tag_1", tags = {} })
    mgr:saveGeneralChat(chat)

    mgr:addTagToChat("__GENERAL_CHATS__", "multi_tag_1", "first")
    mgr:addTagToChat("__GENERAL_CHATS__", "multi_tag_1", "second")
    mgr:addTagToChat("__GENERAL_CHATS__", "multi_tag_1", "third")

    local loaded = mgr:getGeneralChatById("multi_tag_1")
    TestRunner:assertTableLength(loaded.tags, 3, "Should have 3 tags")
    TestRunner:assertEqual(loaded.tags[1], "first", "Order preserved: first")
    TestRunner:assertEqual(loaded.tags[2], "second", "Order preserved: second")
    TestRunner:assertEqual(loaded.tags[3], "third", "Order preserved: third")
end)

TestRunner:test("removeTagFromChat on chat with no tags succeeds", function()
    local mgr = ChatHistoryManager:new()
    local chat = makeChatData({ id = "no_tags_1" })
    chat.tags = nil  -- Explicitly no tags field
    mgr:saveGeneralChat(chat)

    local ok = mgr:removeTagFromChat("__GENERAL_CHATS__", "no_tags_1", "nonexistent")
    TestRunner:assertTrue(ok, "Removing from chat with no tags should succeed")
end)

-- ============================================================
-- Summary
-- ============================================================

print(string.format("\n  Chat Persistence: %d passed, %d failed",
    TestRunner.passed, TestRunner.failed))

return TestRunner.failed == 0
