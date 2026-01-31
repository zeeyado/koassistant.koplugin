local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")
local util = require("util")
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5
local _ = require("koassistant_gettext")

local ChatHistoryManager = {}

-- Constants
ChatHistoryManager.CHAT_DIR = DataStorage:getDataDir() .. "/koassistant_chats"
ChatHistoryManager.GENERAL_CHAT_FILE = DataStorage:getSettingsDir() .. "/koassistant_general_chats.lua"
ChatHistoryManager.MULTI_BOOK_CHAT_FILE = DataStorage:getSettingsDir() .. "/koassistant_multi_book_chats.lua"

--[[
    Helper function for safe metadata writes with validation
    Must be defined early as it's used by many methods below.
--]]

-- Validate chat data structure before writing
-- @param chat: Chat object to validate
-- @return true if valid, false + error message if invalid
local function validateChatData(chat)
    if not chat then
        return false, "Chat data is nil"
    end
    if not chat.id then
        return false, "Missing chat ID"
    end
    if not chat.messages or type(chat.messages) ~= "table" then
        return false, "Invalid messages structure"
    end
    if not chat.timestamp or type(chat.timestamp) ~= "number" then
        return false, "Invalid timestamp"
    end
    return true
end

-- Safely write chats to metadata.lua with validation and verification
-- @param document_path: Full path to document
-- @param chats: Table of chats keyed by chat_id
-- @return true on success, false + error message on failure
local function safeWriteToMetadata(document_path, chats)
    local DocSettings = require("docsettings")

    -- Validate each chat
    for chat_id, chat in pairs(chats) do
        local valid, err = validateChatData(chat)
        if not valid then
            return false, "Invalid chat " .. chat_id .. ": " .. err
        end
    end

    -- Attempt atomic write with error handling
    local ok, err = pcall(function()
        local doc_settings = DocSettings:open(document_path)
        doc_settings:saveSetting("koassistant_chats", chats)
        doc_settings:flush()
    end)

    if not ok then
        return false, "Write failed: " .. (err or "unknown error")
    end

    -- Verify the write succeeded by reading back
    local verify_ok, verify_err = pcall(function()
        local doc_settings = DocSettings:open(document_path)
        local read_back = doc_settings:readSetting("koassistant_chats")
        if not read_back then
            error("Verification failed: data not found after write")
        end
    end)

    if not verify_ok then
        return false, "Verification failed: " .. (verify_err or "unknown error")
    end

    return true
end

function ChatHistoryManager:new()
    local manager = {}
    setmetatable(manager, self)
    self.__index = self
    
    -- Ensure chat directory exists
    self:ensureChatDirectory()
    
    return manager
end

-- Make sure the chat storage directory exists
function ChatHistoryManager:ensureChatDirectory()
    local dir = self.CHAT_DIR
    if not lfs.attributes(dir, "mode") then
        logger.info("Creating chat history directory: " .. dir)
        lfs.mkdir(dir)
    end
end

-- Get document hash for consistent filename generation
function ChatHistoryManager:getDocumentHash(document_path)
    if not document_path then return nil end
    return md5(document_path)
end

-- Get document path from hash
function ChatHistoryManager:getDocumentPathFromHash(doc_hash)
    -- Look through the document directories
    local doc_dir = self.CHAT_DIR .. "/" .. doc_hash
    if lfs.attributes(doc_dir, "mode") then
        -- Try to find a chat file to extract document_path
        for filename in lfs.dir(doc_dir) do
            if filename ~= "." and filename ~= ".." then
                local chat_path = doc_dir .. "/" .. filename
                local chat = self:loadChat(chat_path)
                if chat and chat.document_path then
                    return chat.document_path
                end
            end
        end
    end
    return nil
end

-- Get a list of all documents that have chats
function ChatHistoryManager:getAllDocuments()
    local documents = {}
    
    -- Loop through all subdirectories in the chat directory
    if lfs.attributes(self.CHAT_DIR, "mode") then
        for doc_hash in lfs.dir(self.CHAT_DIR) do
            -- Skip . and ..
            if doc_hash ~= "." and doc_hash ~= ".." then
                local doc_dir = self.CHAT_DIR .. "/" .. doc_hash
                -- Check if it's a directory
                if lfs.attributes(doc_dir, "mode") == "directory" then
                    -- Check if it contains any chat files
                    local has_chats = false
                    for filename in lfs.dir(doc_dir) do
                        -- Only count actual chat files, not backup files
                        if filename ~= "." and filename ~= ".." and not filename:match("%.old$") then
                            has_chats = true
                            break
                        end
                    end
                    
                    if has_chats then
                        -- Get the document path from one of the chats
                        local document_path = self:getDocumentPathFromHash(doc_hash)
                        if document_path then
                            -- Handle special cases for pseudo-document categories
                            local document_title, book_author
                            if document_path == "__GENERAL_CHATS__" then
                                document_title = _("General AI Chats")
                            elseif document_path == "__MULTI_BOOK_CHATS__" then
                                document_title = _("Multi-Book Chats")
                            else
                                -- Try to get book metadata from one of the chats
                                local book_title_found = nil
                                local book_author_found = nil
                                logger.info("ChatHistoryManager: Looking for metadata in " .. doc_dir)
                                for filename in lfs.dir(doc_dir) do
                                    if filename ~= "." and filename ~= ".." and not filename:match("%.old$") then
                                        local chat_path = doc_dir .. "/" .. filename
                                        local chat = self:loadChat(chat_path)
                                        if chat then
                                            logger.info("ChatHistoryManager: Loaded chat - book_title: " .. (chat.book_title or "nil") .. ", book_author: " .. (chat.book_author or "nil"))
                                            if chat.book_title or chat.book_author then
                                                book_title_found = chat.book_title
                                                book_author_found = chat.book_author
                                                break
                                            end
                                        end
                                    end
                                end
                                
                                -- Use book metadata if available, otherwise fall back to filename
                                if book_title_found then
                                    document_title = book_title_found
                                    book_author = book_author_found
                                    logger.info("ChatHistoryManager: Using metadata - title: " .. document_title .. ", author: " .. (book_author or "nil"))
                                else
                                    -- Get the document title (just the filename without path)
                                    document_title = document_path:match("([^/]+)$") or document_path
                                    logger.info("ChatHistoryManager: No metadata found, using filename: " .. document_title)
                                end
                            end
                            
                            table.insert(documents, {
                                hash = doc_hash,
                                path = document_path,
                                title = document_title,
                                author = book_author
                            })
                        end
                    end
                end
            end
        end
    end
    
    -- Sort: General AI Chats first, Multi-Book Chats second, then books alphabetically
    table.sort(documents, function(a, b)
        -- General chats always come first
        if a.path == "__GENERAL_CHATS__" then
            return true
        elseif b.path == "__GENERAL_CHATS__" then
            return false
        end
        -- Multi-book chats come second
        if a.path == "__MULTI_BOOK_CHATS__" then
            return true
        elseif b.path == "__MULTI_BOOK_CHATS__" then
            return false
        end

        -- Sort alphabetically by title
        return a.title < b.title
    end)
    
    return documents
end

-- Get document-specific chat directory
function ChatHistoryManager:getDocumentChatDir(document_path)
    local doc_hash = self:getDocumentHash(document_path)
    if not doc_hash then return nil end
    
    local doc_dir = self.CHAT_DIR .. "/" .. doc_hash
    if not lfs.attributes(doc_dir, "mode") then
        lfs.mkdir(doc_dir)
    end
    
    return doc_dir
end

-- Generate a unique ID for a new chat
function ChatHistoryManager:generateChatId()
    return os.time() .. "_" .. math.random(1000, 9999)
end

-- Save a chat session
function ChatHistoryManager:saveChat(document_path, chat_title, message_history, metadata)
    if not document_path or not message_history then
        logger.warn("Cannot save chat: missing document path or message history")
        return false
    end

    local doc_dir = self:getDocumentChatDir(document_path)
    if not doc_dir then
        logger.warn("Cannot create document directory for chat history")
        return false
    end

    -- Generate a chat ID if not provided in metadata
    local chat_id = (metadata and metadata.id) or self:generateChatId()
    
    -- Create chat data structure
    local chat_data = {
        id = chat_id,
        title = chat_title or "Conversation",
        document_path = document_path,
        timestamp = os.time(),
        messages = message_history:getMessages(),
        model = message_history:getModel(),
        metadata = metadata or {},
        -- Store book metadata at top level for easier access
        book_title = metadata and metadata.book_title or nil,
        book_author = metadata and metadata.book_author or nil,
        -- Store prompt action for continued chats
        prompt_action = message_history.prompt_action or nil,
        -- Store launch context for general chats started from within a book
        launch_context = metadata and metadata.launch_context or nil,
        -- Store domain for filtering and context (optional, set at chat start only)
        domain = metadata and metadata.domain or nil,
        -- Store tags for organization (can be modified anytime)
        tags = metadata and metadata.tags or {},
        -- Store highlighted text for display toggle in continued chats (not in messages/export)
        original_highlighted_text = metadata and metadata.original_highlighted_text or nil,
    }
    
    -- Check if this is an update to an existing chat
    local chat_path = doc_dir .. "/" .. chat_id .. ".lua"
    local existing_chat = nil
    if lfs.attributes(chat_path, "mode") then
        logger.info("Updating existing chat: " .. chat_id)
        existing_chat = self:loadChat(chat_path)
        
        -- Remove any old backup file that might exist
        local backup_path = chat_path .. ".old"
        if lfs.attributes(backup_path, "mode") then
            os.remove(backup_path)
        end
        
        -- Rename the current file to .old as a backup
        os.rename(chat_path, backup_path)
    end
    
    -- Save to file
    local ok, err = pcall(function()
        local settings = LuaSettings:open(chat_path)
        settings:saveSetting("chat", chat_data)
        settings:flush()
    end)
    
    if not ok then
        logger.warn("Failed to save chat history: " .. (err or "unknown error"))
        -- If we failed to save and had renamed the original file, try to restore it
        if existing_chat then
            os.rename(chat_path .. ".old", chat_path)
        end
        return false
    end

    -- Update last opened tracking to keep it in sync when content is added
    -- This ensures last_opened and last_saved point to the same chat when content is modified
    local message_count = #chat_data.messages
    self:setLastOpenedChat(document_path, chat_id, message_count)

    logger.info("Saved chat history: " .. chat_id .. " for document: " .. document_path)
    return chat_id
end

-- Get all chats for a document
function ChatHistoryManager:getChatsForDocument(document_path)
    if not document_path then 
        logger.warn("Cannot get chats: document_path is nil")
        return {} 
    end
    
    local doc_dir = self:getDocumentChatDir(document_path)
    if not doc_dir or not lfs.attributes(doc_dir, "mode") then
        logger.info("No chat directory found for document: " .. document_path)
        return {}
    end
    
    local chats = {}
    for filename in lfs.dir(doc_dir) do
        -- Skip . and .. and backup files ending with .old
        if filename ~= "." and filename ~= ".." and not filename:match("%.old$") then
            local chat_path = doc_dir .. "/" .. filename
            logger.info("Loading chat file: " .. chat_path)
            local chat = self:loadChat(chat_path)
            if chat then
                logger.info("Loaded chat: " .. (chat.id or "unknown") .. " - " .. (chat.title or "Untitled"))
                table.insert(chats, chat)
            end
        end
    end
    
    -- Sort by timestamp (newest first)
    table.sort(chats, function(a, b) 
        return (a.timestamp or 0) > (b.timestamp or 0)
    end)
    
    logger.info("Found " .. #chats .. " chats for document: " .. document_path)
    return chats
end

-- Load a chat from file
function ChatHistoryManager:loadChat(chat_path)
    local ok, settings = pcall(LuaSettings.open, LuaSettings, chat_path)
    if not ok or not settings then
        logger.warn("Failed to open chat file: " .. chat_path)
        return nil
    end
    
    local chat_data = settings:readSetting("chat")
    if not chat_data then
        logger.warn("No chat data found in file: " .. chat_path)
        return nil
    end
    
    -- Validate required fields
    if not chat_data.id then
        logger.warn("Chat missing ID in file: " .. chat_path)
        chat_data.id = string.gsub(chat_path, "^.*/([^/]+)%.lua$", "%1")
    end
    
    if not chat_data.messages or #chat_data.messages == 0 then
        logger.warn("Chat has no messages in file: " .. chat_path)
    end
    
    return chat_data
end

-- Get a specific chat by ID
function ChatHistoryManager:getChatById(document_path, chat_id)
    if not document_path or not chat_id then return nil end

    -- Route to v2 or v1 storage
    if self:useDocSettingsStorage() then
        -- v2: metadata.lua, general chats, or multi-book chats storage
        if document_path == "__GENERAL_CHATS__" then
            return self:getGeneralChatById(chat_id)
        elseif document_path == "__MULTI_BOOK_CHATS__" then
            return self:getMultiBookChatById(chat_id)
        else
            -- Read chat from metadata.lua
            if lfs.attributes(document_path, "mode") then
                local DocSettings = require("docsettings")
                local doc_settings = DocSettings:open(document_path)
                local chats = doc_settings:readSetting("koassistant_chats", {})
                return chats[chat_id]
            else
                logger.warn("getChatById: Document not found: " .. document_path)
                return nil
            end
        end
    else
        -- v1: Legacy hash-based storage
        local doc_dir = self:getDocumentChatDir(document_path)
        if not doc_dir then return nil end

        local chat_path = doc_dir .. "/" .. chat_id .. ".lua"
        return self:loadChat(chat_path)
    end
end

-- Delete a chat
function ChatHistoryManager:deleteChat(document_path, chat_id)
    if not document_path or not chat_id then return false end

    -- Route to v2 or v1 storage
    if self:useDocSettingsStorage() then
        -- v2: DocSettings-based storage
        if document_path == "__GENERAL_CHATS__" then
            return self:deleteGeneralChat(chat_id)
        elseif document_path == "__MULTI_BOOK_CHATS__" then
            return self:deleteMultiBookChat(chat_id)
        else
            return self:deleteChatFromDocSettings(nil, chat_id, document_path)
        end
    else
        -- v1: Legacy hash-based storage
        local doc_dir = self:getDocumentChatDir(document_path)
        if not doc_dir then return false end

        local chat_path = doc_dir .. "/" .. chat_id .. ".lua"
        if lfs.attributes(chat_path, "mode") then
            os.remove(chat_path)
            logger.info("Deleted chat: " .. chat_id)
            return true
        end

        return false
    end
end

-- Delete all chats for a specific document
function ChatHistoryManager:deleteAllChatsForDocument(document_path)
    if not document_path then return 0 end

    local doc_dir = self:getDocumentChatDir(document_path)
    if not doc_dir or not lfs.attributes(doc_dir, "mode") then
        return 0
    end

    local deleted_count = 0

    -- Delete all chat files in the document directory
    for filename in lfs.dir(doc_dir) do
        if filename ~= "." and filename ~= ".." then
            local file_path = doc_dir .. "/" .. filename
            local attr = lfs.attributes(file_path, "mode")
            if attr == "file" then
                os.remove(file_path)
                deleted_count = deleted_count + 1
                logger.info("Deleted chat file: " .. filename)
            end
        end
    end

    -- Remove the empty directory
    local ok, err = os.remove(doc_dir)
    if ok then
        logger.info("Removed empty document directory: " .. doc_dir)
    else
        logger.warn("Could not remove document directory: " .. (err or "unknown error"))
    end

    logger.info("Deleted " .. deleted_count .. " chats for document: " .. document_path)
    return deleted_count
end

-- Delete all chats across all documents
function ChatHistoryManager:deleteAllChats()
    if not lfs.attributes(self.CHAT_DIR, "mode") then
        return 0
    end

    local total_deleted = 0
    local docs_deleted = 0

    -- Iterate through all document directories
    for doc_hash in lfs.dir(self.CHAT_DIR) do
        if doc_hash ~= "." and doc_hash ~= ".." then
            local doc_dir = self.CHAT_DIR .. "/" .. doc_hash
            local attr = lfs.attributes(doc_dir, "mode")

            if attr == "directory" then
                -- Delete all files in this directory
                for filename in lfs.dir(doc_dir) do
                    if filename ~= "." and filename ~= ".." then
                        local file_path = doc_dir .. "/" .. filename
                        if lfs.attributes(file_path, "mode") == "file" then
                            os.remove(file_path)
                            total_deleted = total_deleted + 1
                        end
                    end
                end

                -- Remove the empty directory
                os.remove(doc_dir)
                docs_deleted = docs_deleted + 1
            end
        end
    end

    logger.info("Deleted " .. total_deleted .. " chats from " .. docs_deleted .. " documents")
    return total_deleted, docs_deleted
end

-- Rename a chat
function ChatHistoryManager:renameChat(document_path, chat_id, new_title)
    if not document_path or not chat_id or not new_title then
        logger.warn("Cannot rename chat: missing document path, chat ID, or new title")
        return false
    end

    -- Route to v2 or v1 storage
    if self:useDocSettingsStorage() then
        -- v2: DocSettings-based storage
        if document_path == "__GENERAL_CHATS__" then
            return self:updateGeneralChat(chat_id, { title = new_title })
        elseif document_path == "__MULTI_BOOK_CHATS__" then
            return self:updateMultiBookChat(chat_id, { title = new_title })
        else
            return self:updateChatInDocSettings(nil, chat_id, { title = new_title }, document_path)
        end
    else
        -- v1: Legacy hash-based storage
        -- Load the chat
        local chat = self:getChatById(document_path, chat_id)
        if not chat then
            logger.warn("Cannot rename chat: chat not found")
            return false
        end

        -- Update the title
        chat.title = new_title

        -- Save the chat back to the file
        local doc_dir = self:getDocumentChatDir(document_path)
        if not doc_dir then return false end

        local chat_path = doc_dir .. "/" .. chat_id .. ".lua"

        -- Create backup
        local backup_path = chat_path .. ".old"
        if lfs.attributes(backup_path, "mode") then
            os.remove(backup_path)
        end

        -- Rename the current file to .old as a backup
        os.rename(chat_path, backup_path)

        -- Save updated chat
        local ok, err = pcall(function()
            local settings = LuaSettings:open(chat_path)
            settings:saveSetting("chat", chat)
            settings:flush()
        end)

        if not ok then
            logger.warn("Failed to save renamed chat: " .. (err or "unknown error"))
            -- Restore backup on failure
            os.rename(backup_path, chat_path)
            return false
        end

        logger.info("Renamed chat: " .. chat_id .. " to: " .. new_title)
        return true
    end
end

-- Export chat to text format
function ChatHistoryManager:exportChatAsText(document_path, chat_id)
    local chat = self:getChatById(document_path, chat_id)
    if not chat then return nil end

    local result = {}
    table.insert(result, "Chat: " .. chat.title)
    table.insert(result, "Date: " .. os.date("%Y-%m-%d %H:%M", chat.timestamp))
    table.insert(result, "Document: " .. chat.document_path)
    table.insert(result, "Model: " .. (chat.model or "Unknown"))

    -- Include launch context if available (for general chats launched from a book)
    if chat.launch_context and chat.launch_context.title then
        local launch_info = "Launched from: " .. chat.launch_context.title
        if chat.launch_context.author then
            launch_info = launch_info .. " by " .. chat.launch_context.author
        end
        table.insert(result, launch_info)
    end

    table.insert(result, "")
    
    -- Format messages
    for _, msg in ipairs(chat.messages) do
        local role = msg.role:gsub("^%l", string.upper)
        local content = msg.content
        
        -- Skip context messages in export by default
        if not msg.is_context then
            table.insert(result, role .. ": " .. content)
            table.insert(result, "")
        end
    end
    
    return table.concat(result, "\n")
end

-- Export chat to markdown format
function ChatHistoryManager:exportChatAsMarkdown(document_path, chat_id)
    local chat = self:getChatById(document_path, chat_id)
    if not chat then return nil end

    local result = {}
    table.insert(result, "# " .. chat.title)
    table.insert(result, "**Date:** " .. os.date("%Y-%m-%d %H:%M", chat.timestamp))
    table.insert(result, "**Document:** " .. chat.document_path)
    table.insert(result, "**Model:** " .. (chat.model or "Unknown"))

    -- Include launch context if available (for general chats launched from a book)
    if chat.launch_context and chat.launch_context.title then
        local launch_info = "**Launched from:** " .. chat.launch_context.title
        if chat.launch_context.author then
            launch_info = launch_info .. " by " .. chat.launch_context.author
        end
        table.insert(result, launch_info)
    end

    table.insert(result, "")
    
    -- Format messages
    for _, msg in ipairs(chat.messages) do
        local role = msg.role:gsub("^%l", string.upper)
        local content = msg.content
        
        -- Skip context messages in export by default
        if not msg.is_context then
            table.insert(result, "### " .. role)
            table.insert(result, content)
            table.insert(result, "")
        end
    end
    
    return table.concat(result, "\n")
end

-- Unified export method using Export module (respects user settings)
-- @param document_path string document path
-- @param chat_id string chat ID
-- @param content string "full" | "qa" | "response" (what to include)
-- @param style string "markdown" | "text" (how to format)
-- @return string formatted export text
function ChatHistoryManager:exportChat(document_path, chat_id, content, style)
    local chat = self:getChatById(document_path, chat_id)
    if not chat then return nil end

    local Export = require("koassistant_export")
    local data = Export.fromSavedChat(chat)
    return Export.format(data, content, style)
end

-- Get the most recently saved chat across all documents
function ChatHistoryManager:getMostRecentChat()
    local most_recent_chat = nil
    local most_recent_timestamp = 0
    local most_recent_doc_path = nil

    -- Route to v2/v3 or v1 storage
    if self:useDocSettingsStorage() then
        -- v2/v3: Scan chat index + general chats for most recent timestamp

        -- Check general chats first
        local general_chats = self:getGeneralChats()
        for _idx, chat in ipairs(general_chats) do
            if chat and chat.timestamp and chat.timestamp > 0 and
               chat.messages and #chat.messages > 0 and
               chat.timestamp > most_recent_timestamp then
                most_recent_chat = chat
                most_recent_timestamp = chat.timestamp
                most_recent_doc_path = "__GENERAL_CHATS__"
            end
        end

        -- Check multi-book chats
        local multi_book_chats = self:getMultiBookChats()
        for _idx, chat in ipairs(multi_book_chats) do
            if chat and chat.timestamp and chat.timestamp > 0 and
               chat.messages and #chat.messages > 0 and
               chat.timestamp > most_recent_timestamp then
                most_recent_chat = chat
                most_recent_timestamp = chat.timestamp
                most_recent_doc_path = "__MULTI_BOOK_CHATS__"
            end
        end

        -- Scan all documents from chat index
        local index = self:getChatIndex()
        local DocSettings = require("docsettings")
        for doc_path, info in pairs(index) do
            if doc_path ~= "__GENERAL_CHATS__" and lfs.attributes(doc_path, "mode") then
                -- Read chats from metadata.lua for this document
                local doc_settings = DocSettings:open(doc_path)
                local chats_table = doc_settings:readSetting("koassistant_chats", {})

                -- Check each chat's timestamp
                for chat_id, chat in pairs(chats_table) do
                    if chat and chat.timestamp and chat.timestamp > 0 and
                       chat.messages and #chat.messages > 0 and
                       chat.timestamp > most_recent_timestamp then
                        most_recent_chat = chat
                        most_recent_timestamp = chat.timestamp
                        most_recent_doc_path = doc_path
                    end
                end
            end
        end
    else
        -- v1: Loop through all document directories
        if lfs.attributes(self.CHAT_DIR, "mode") then
            for doc_hash in lfs.dir(self.CHAT_DIR) do
                if doc_hash ~= "." and doc_hash ~= ".." then
                    local doc_dir = self.CHAT_DIR .. "/" .. doc_hash
                    if lfs.attributes(doc_dir, "mode") == "directory" then
                        -- Get chats from this document directory
                        for filename in lfs.dir(doc_dir) do
                            if filename ~= "." and filename ~= ".." and not filename:match("%.old$") then
                                local chat_path = doc_dir .. "/" .. filename
                                local chat = self:loadChat(chat_path)
                                -- Validate chat has actual content
                                if chat and chat.timestamp and chat.timestamp > 0 and
                                   chat.messages and #chat.messages > 0 and
                                   chat.timestamp > most_recent_timestamp then
                                    most_recent_chat = chat
                                    most_recent_timestamp = chat.timestamp
                                    -- Get document path from the chat itself
                                    most_recent_doc_path = chat.document_path
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if most_recent_chat and most_recent_doc_path then
        logger.info("Found most recent chat: " .. (most_recent_chat.title or "Untitled") ..
                   " with timestamp: " .. most_recent_timestamp)
        return most_recent_chat, most_recent_doc_path
    end

    return nil, nil
end

-- Settings file for tracking last opened chat
local LAST_OPENED_FILE = DataStorage:getSettingsDir() .. "/koassistant_last_opened.lua"

-- Track the last opened chat (called when a chat is opened/continued)
-- @param document_path: The document path
-- @param chat_id: The chat ID
-- @param message_count: Optional message count to track if chat was modified
function ChatHistoryManager:setLastOpenedChat(document_path, chat_id, message_count)
    if not document_path or not chat_id then
        logger.warn("setLastOpenedChat: Missing document_path or chat_id")
        return false
    end

    local settings = LuaSettings:open(LAST_OPENED_FILE)
    settings:saveSetting("last_opened", {
        document_path = document_path,
        chat_id = chat_id,
        timestamp = os.time(),
        message_count = message_count or 0,
    })
    settings:flush()
    logger.info("Saved last opened chat: " .. chat_id .. " for document: " .. document_path ..
                (message_count and (" with " .. message_count .. " messages") or ""))
    return true
end

-- Get the last opened chat (regardless of when it was last saved)
function ChatHistoryManager:getLastOpenedChat()
    local settings = LuaSettings:open(LAST_OPENED_FILE)
    local last_opened = settings:readSetting("last_opened")

    if not last_opened or not last_opened.document_path or not last_opened.chat_id then
        logger.info("No last opened chat found")
        return nil, nil
    end

    -- Try to load the chat from disk
    local chat
    if self:useDocSettingsStorage() then
        -- v2: metadata.lua, general, or multi-book storage
        if last_opened.document_path == "__GENERAL_CHATS__" then
            chat = self:getGeneralChatById(last_opened.chat_id)
        elseif last_opened.document_path == "__MULTI_BOOK_CHATS__" then
            chat = self:getMultiBookChatById(last_opened.chat_id)
        else
            -- Read chat from metadata.lua for that document
            if lfs.attributes(last_opened.document_path, "mode") then
                local DocSettings = require("docsettings")
                local doc_settings = DocSettings:open(last_opened.document_path)
                local chats = doc_settings:readSetting("koassistant_chats", {})
                chat = chats[last_opened.chat_id]
            end
        end
    else
        -- v1: Legacy hash-based storage
        chat = self:getChatById(last_opened.document_path, last_opened.chat_id)
    end

    if not chat then
        logger.warn("Last opened chat no longer exists: " .. last_opened.chat_id)
        return nil, nil
    end

    return chat, last_opened.document_path
end

-- Get all chats grouped by domain
-- Returns a table with domain IDs as keys and arrays of {chat, document_path} as values
-- Chats without a domain are grouped under "untagged"
function ChatHistoryManager:getChatsByDomain()
    local domains = {}
    domains["untagged"] = {}

    -- Loop through all document directories
    if not lfs.attributes(self.CHAT_DIR, "mode") then
        return domains
    end

    for doc_hash in lfs.dir(self.CHAT_DIR) do
        if doc_hash ~= "." and doc_hash ~= ".." then
            local doc_dir = self.CHAT_DIR .. "/" .. doc_hash
            if lfs.attributes(doc_dir, "mode") == "directory" then
                -- Get chats from this document directory
                for filename in lfs.dir(doc_dir) do
                    if filename ~= "." and filename ~= ".." and not filename:match("%.old$") then
                        local chat_path = doc_dir .. "/" .. filename
                        local chat = self:loadChat(chat_path)
                        if chat and chat.messages and #chat.messages > 0 then
                            local domain_key = chat.domain or "untagged"
                            if not domains[domain_key] then
                                domains[domain_key] = {}
                            end
                            table.insert(domains[domain_key], {
                                chat = chat,
                                document_path = chat.document_path
                            })
                        end
                    end
                end
            end
        end
    end

    -- Sort chats within each domain by timestamp (newest first)
    for domain_key, chats in pairs(domains) do
        table.sort(chats, function(a, b)
            return (a.chat.timestamp or 0) > (b.chat.timestamp or 0)
        end)
    end

    return domains
end

-- Get count of chats per domain
function ChatHistoryManager:getDomainChatCounts()
    local chats_by_domain = self:getChatsByDomain()
    local counts = {}

    for domain_key, chats in pairs(chats_by_domain) do
        counts[domain_key] = #chats
    end

    return counts
end

-- Add a tag to a chat
function ChatHistoryManager:addTagToChat(document_path, chat_id, tag)
    if not document_path or not chat_id or not tag or tag == "" then
        logger.warn("Cannot add tag: missing required parameters")
        return false
    end

    -- Normalize the tag (trim whitespace)
    tag = tag:match("^%s*(.-)%s*$")
    if tag == "" then return false end

    -- Route to v2 or v1 storage
    if self:useDocSettingsStorage() then
        -- v2: Load chat from metadata.lua, general, or multi-book storage, add tag, update
        local chat
        if document_path == "__GENERAL_CHATS__" then
            chat = self:getGeneralChatById(chat_id)
        elseif document_path == "__MULTI_BOOK_CHATS__" then
            chat = self:getMultiBookChatById(chat_id)
        else
            if lfs.attributes(document_path, "mode") then
                local DocSettings = require("docsettings")
                local doc_settings = DocSettings:open(document_path)
                local chats = doc_settings:readSetting("koassistant_chats", {})
                chat = chats[chat_id]
            end
        end

        if not chat then
            logger.warn("Cannot add tag: chat not found")
            return false
        end

        -- Initialize tags if not present
        if not chat.tags then
            chat.tags = {}
        end

        -- Check if tag already exists
        for _idx, existing_tag in ipairs(chat.tags) do
            if existing_tag == tag then
                return true  -- Tag already exists, consider it success
            end
        end

        -- Add the tag
        table.insert(chat.tags, tag)

        -- Save back
        if document_path == "__GENERAL_CHATS__" then
            return self:updateGeneralChat(chat_id, { tags = chat.tags })
        elseif document_path == "__MULTI_BOOK_CHATS__" then
            return self:updateMultiBookChat(chat_id, { tags = chat.tags })
        else
            return self:updateChatInDocSettings(nil, chat_id, { tags = chat.tags }, document_path)
        end
    else
        -- v1: Legacy hash-based storage
        -- Load the chat
        local chat = self:getChatById(document_path, chat_id)
        if not chat then
            logger.warn("Cannot add tag: chat not found")
            return false
        end

        -- Initialize tags array if needed
        if not chat.tags then
            chat.tags = {}
        end

        -- Check if tag already exists
        for _, existing_tag in ipairs(chat.tags) do
            if existing_tag == tag then
                logger.info("Tag already exists: " .. tag)
                return true  -- Already has this tag
            end
        end

        -- Add the tag
        table.insert(chat.tags, tag)

        -- Save the chat back to the file
        return self:updateChatData(document_path, chat_id, chat)
    end
end

-- Remove a tag from a chat
function ChatHistoryManager:removeTagFromChat(document_path, chat_id, tag)
    if not document_path or not chat_id or not tag then
        logger.warn("Cannot remove tag: missing required parameters")
        return false
    end

    -- Route to v2 or v1 storage
    if self:useDocSettingsStorage() then
        -- v2: Load chat from metadata.lua, general, or multi-book storage, remove tag, update
        local chat
        if document_path == "__GENERAL_CHATS__" then
            chat = self:getGeneralChatById(chat_id)
        elseif document_path == "__MULTI_BOOK_CHATS__" then
            chat = self:getMultiBookChatById(chat_id)
        else
            if lfs.attributes(document_path, "mode") then
                local DocSettings = require("docsettings")
                local doc_settings = DocSettings:open(document_path)
                local chats = doc_settings:readSetting("koassistant_chats", {})
                chat = chats[chat_id]
            end
        end

        if not chat then
            logger.warn("Cannot remove tag: chat not found")
            return false
        end

        if not chat.tags then
            return true  -- No tags to remove
        end

        -- Remove the tag
        local new_tags = {}
        for _idx, existing_tag in ipairs(chat.tags) do
            if existing_tag ~= tag then
                table.insert(new_tags, existing_tag)
            end
        end

        chat.tags = new_tags

        -- Save back
        if document_path == "__GENERAL_CHATS__" then
            return self:updateGeneralChat(chat_id, { tags = new_tags })
        elseif document_path == "__MULTI_BOOK_CHATS__" then
            return self:updateMultiBookChat(chat_id, { tags = new_tags })
        else
            return self:updateChatInDocSettings(nil, chat_id, { tags = new_tags }, document_path)
        end
    else
        -- v1: Legacy hash-based storage
        -- Load the chat
        local chat = self:getChatById(document_path, chat_id)
        if not chat then
            logger.warn("Cannot remove tag: chat not found")
            return false
        end

        if not chat.tags then
            return true  -- No tags to remove
        end

        -- Find and remove the tag
        local found = false
        for i, existing_tag in ipairs(chat.tags) do
            if existing_tag == tag then
                table.remove(chat.tags, i)
                found = true
                break
            end
        end

        if not found then
            return true  -- Tag wasn't there anyway
        end

        -- Save the chat back to the file
        return self:updateChatData(document_path, chat_id, chat)
    end
end

-- Update chat data (internal helper for tag operations)
function ChatHistoryManager:updateChatData(document_path, chat_id, chat_data)
    local doc_dir = self:getDocumentChatDir(document_path)
    if not doc_dir then return false end

    local chat_path = doc_dir .. "/" .. chat_id .. ".lua"

    -- Create backup
    local backup_path = chat_path .. ".old"
    if lfs.attributes(backup_path, "mode") then
        os.remove(backup_path)
    end

    -- Rename the current file to .old as a backup
    if lfs.attributes(chat_path, "mode") then
        os.rename(chat_path, backup_path)
    end

    -- Save updated chat
    local ok, err = pcall(function()
        local settings = LuaSettings:open(chat_path)
        settings:saveSetting("chat", chat_data)
        settings:flush()
    end)

    if not ok then
        logger.warn("Failed to update chat data: " .. (err or "unknown error"))
        -- Restore backup on failure
        if lfs.attributes(backup_path, "mode") then
            os.rename(backup_path, chat_path)
        end
        return false
    end

    return true
end

-- Get all unique tags across all chats
function ChatHistoryManager:getAllTags()
    local tags_set = {}

    -- Loop through all document directories
    if not lfs.attributes(self.CHAT_DIR, "mode") then
        return {}
    end

    for doc_hash in lfs.dir(self.CHAT_DIR) do
        if doc_hash ~= "." and doc_hash ~= ".." then
            local doc_dir = self.CHAT_DIR .. "/" .. doc_hash
            if lfs.attributes(doc_dir, "mode") == "directory" then
                -- Get chats from this document directory
                for filename in lfs.dir(doc_dir) do
                    if filename ~= "." and filename ~= ".." and not filename:match("%.old$") then
                        local chat_path = doc_dir .. "/" .. filename
                        local chat = self:loadChat(chat_path)
                        if chat and chat.tags then
                            for _, tag in ipairs(chat.tags) do
                                tags_set[tag] = true
                            end
                        end
                    end
                end
            end
        end
    end

    -- Convert set to sorted array
    local tags = {}
    for tag in pairs(tags_set) do
        table.insert(tags, tag)
    end
    table.sort(tags)

    return tags
end

-- Get all chats with a specific tag
function ChatHistoryManager:getChatsByTag(tag)
    local chats = {}

    if not tag then return chats end

    -- Loop through all document directories
    if not lfs.attributes(self.CHAT_DIR, "mode") then
        return chats
    end

    for doc_hash in lfs.dir(self.CHAT_DIR) do
        if doc_hash ~= "." and doc_hash ~= ".." then
            local doc_dir = self.CHAT_DIR .. "/" .. doc_hash
            if lfs.attributes(doc_dir, "mode") == "directory" then
                -- Get chats from this document directory
                for filename in lfs.dir(doc_dir) do
                    if filename ~= "." and filename ~= ".." and not filename:match("%.old$") then
                        local chat_path = doc_dir .. "/" .. filename
                        local chat = self:loadChat(chat_path)
                        if chat and chat.tags and chat.messages and #chat.messages > 0 then
                            for _, chat_tag in ipairs(chat.tags) do
                                if chat_tag == tag then
                                    table.insert(chats, {
                                        chat = chat,
                                        document_path = chat.document_path
                                    })
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Sort by timestamp (newest first)
    table.sort(chats, function(a, b)
        return (a.chat.timestamp or 0) > (b.chat.timestamp or 0)
    end)

    return chats
end

-- Get count of chats per tag
function ChatHistoryManager:getTagChatCounts()
    local counts = {}

    -- Loop through all document directories
    if not lfs.attributes(self.CHAT_DIR, "mode") then
        return counts
    end

    for doc_hash in lfs.dir(self.CHAT_DIR) do
        if doc_hash ~= "." and doc_hash ~= ".." then
            local doc_dir = self.CHAT_DIR .. "/" .. doc_hash
            if lfs.attributes(doc_dir, "mode") == "directory" then
                -- Get chats from this document directory
                for filename in lfs.dir(doc_dir) do
                    if filename ~= "." and filename ~= ".." and not filename:match("%.old$") then
                        local chat_path = doc_dir .. "/" .. filename
                        local chat = self:loadChat(chat_path)
                        if chat and chat.tags and chat.messages and #chat.messages > 0 then
                            for _, tag in ipairs(chat.tags) do
                                counts[tag] = (counts[tag] or 0) + 1
                            end
                        end
                    end
                end
            end
        end
    end

    return counts
end

--[[ ============================================================================
     NEW STORAGE SYSTEM (v2) - Metadata.lua Integration
     ============================================================================

     These methods implement storage in KOReader's native metadata.lua file
     within each book's .sdr folder. This fixes the critical bug where chat
     history was lost when files were moved by leveraging KOReader's built-in
     DocSettings.updateLocation() mechanism.

     Benefits:
     - Chats automatically migrate when files move (via DocSettings.updateLocation())
     - Works across all storage modes ("doc", "dir", "hash")
     - No plugin hooks needed - KOReader handles migration
     - Atomic writes with validation and verification
     - Namespaced keys prevent conflicts with KOReader metadata

     Storage format:
     - Document chats: book.epub.sdr/metadata.lua under "koassistant_chats" key
     - General chats: Stored in dedicated global settings file
     - Chat index: Lightweight index in global settings for fast browsing

     Safety measures:
     - Validation of chat data before writes
     - Atomic writes using LuaSettings temp file + rename pattern
     - Post-write verification by reading back
     - Namespaced under "koassistant_chats" key (won't conflict with KOReader)

     Version history:
     - v1: Hash-based directories (koassistant_chats/{hash}/)
     - v2: Stored in metadata.lua (current - fixes move tracking)
     - v3: DEPRECATED - Separate koassistant_chats.lua file (doesn't migrate with moves)
--]]

-- Check if we should use new storage (v3) or legacy storage (v1)
function ChatHistoryManager:useDocSettingsStorage()
    -- G_reader_settings is a global in KOReader
    local version = G_reader_settings:readSetting("chat_storage_version", 1)
    return version >= 2  -- Both v2 and v3 use similar methods, just different file
end

--[[
    Storage methods for document chats
--]]

-- Save chat to metadata.lua
-- @param ui: ReaderUI object (optional, kept for backwards compatibility)
-- @param chat_data: Complete chat data structure (must include document_path)
-- @return chat_id on success, false on failure
function ChatHistoryManager:saveChatToDocSettings(ui, chat_data)
    if not chat_data or not chat_data.id then
        logger.warn("saveChatToDocSettings: Missing chat_data or chat_data.id")
        return false
    end

    if not chat_data.document_path or chat_data.document_path == "__GENERAL_CHATS__" or chat_data.document_path == "__MULTI_BOOK_CHATS__" then
        logger.warn("saveChatToDocSettings: Invalid document_path, use saveGeneralChat or saveMultiBookChat instead")
        return false
    end

    -- Verify document exists
    if not lfs.attributes(chat_data.document_path, "mode") then
        logger.warn("saveChatToDocSettings: Document not found: " .. chat_data.document_path)
        return false
    end

    -- Read existing chats from metadata.lua
    local DocSettings = require("docsettings")
    local doc_settings = DocSettings:open(chat_data.document_path)
    local chats = doc_settings:readSetting("koassistant_chats", {})

    -- Add or update this chat (keyed by ID)
    chats[chat_data.id] = chat_data

    -- Safe write to metadata.lua with validation
    local ok, err = safeWriteToMetadata(chat_data.document_path, chats)
    if not ok then
        logger.warn("saveChatToDocSettings: " .. (err or "Write failed"))
        return false
    end

    -- Update chat index
    self:updateChatIndex(chat_data.document_path, "save", chat_data.id, chats)

    logger.info("Saved chat to metadata.lua: " .. chat_data.id .. " (" .. chat_data.document_path .. ")")
    return chat_data.id
end

-- Load all chats for document from metadata.lua
-- @param ui: ReaderUI object or document_path string
-- @return array of chat objects sorted by timestamp (newest first)
function ChatHistoryManager:getChatsFromDocSettings(ui)
    -- Extract document path from ui or use directly if string
    local document_path
    if type(ui) == "string" then
        document_path = ui
    elseif ui and ui.document and ui.document.file then
        document_path = ui.document.file
    else
        logger.warn("getChatsFromDocSettings: Missing ui or document_path")
        return {}
    end

    -- Verify document exists
    if not lfs.attributes(document_path, "mode") then
        logger.warn("getChatsFromDocSettings: Document not found: " .. document_path)
        return {}
    end

    -- Read chats from metadata.lua
    local DocSettings = require("docsettings")
    local doc_settings = DocSettings:open(document_path)
    local chats_table = doc_settings:readSetting("koassistant_chats", {})

    -- Convert table to sorted array
    local chats = {}
    for chat_id, chat_data in pairs(chats_table) do
        table.insert(chats, chat_data)
    end

    -- Sort by timestamp (newest first)
    table.sort(chats, function(a, b)
        return (a.timestamp or 0) > (b.timestamp or 0)
    end)

    logger.info("Loaded " .. #chats .. " chats from metadata.lua")
    return chats
end

-- Get specific chat by ID from metadata.lua
-- @param ui: ReaderUI object or document_path string
-- @param chat_id: Chat ID to load
-- @return chat data or nil if not found
function ChatHistoryManager:getChatByIdFromDocSettings(ui, chat_id)
    if not chat_id then
        logger.warn("getChatByIdFromDocSettings: Missing chat_id")
        return nil
    end

    -- Extract document path from ui or use directly if string
    local document_path
    if type(ui) == "string" then
        document_path = ui
    elseif ui and ui.document and ui.document.file then
        document_path = ui.document.file
    else
        logger.warn("getChatByIdFromDocSettings: Missing ui or document_path")
        return nil
    end

    -- Verify document exists
    if not lfs.attributes(document_path, "mode") then
        logger.warn("getChatByIdFromDocSettings: Document not found: " .. document_path)
        return nil
    end

    -- Read chats from metadata.lua
    local DocSettings = require("docsettings")
    local doc_settings = DocSettings:open(document_path)
    local chats = doc_settings:readSetting("koassistant_chats", {})

    return chats[chat_id]
end

-- Delete chat from metadata.lua
-- @param ui: ReaderUI object or nil
-- @param chat_id: Chat ID to delete
-- @param document_path: Document path (required if ui is nil or doesn't have document.file)
-- @return true on success, false on failure
function ChatHistoryManager:deleteChatFromDocSettings(ui, chat_id, document_path)
    if not chat_id then
        logger.warn("deleteChatFromDocSettings: Missing chat_id")
        return false
    end

    -- Extract document path from ui or use provided document_path
    local actual_doc_path = document_path
    if ui and ui.document and ui.document.file then
        actual_doc_path = ui.document.file
    end

    if not actual_doc_path then
        logger.warn("deleteChatFromDocSettings: Missing document_path")
        return false
    end

    -- Verify document exists
    if not lfs.attributes(actual_doc_path, "mode") then
        logger.warn("deleteChatFromDocSettings: Document not found: " .. actual_doc_path)
        return false
    end

    -- Read chats from metadata.lua
    local DocSettings = require("docsettings")
    local doc_settings = DocSettings:open(actual_doc_path)
    local chats = doc_settings:readSetting("koassistant_chats", {})

    -- Check if chat exists
    if not chats[chat_id] then
        logger.warn("deleteChatFromDocSettings: Chat not found: " .. chat_id)
        return false
    end

    local stored_path = chats[chat_id].document_path

    -- Delete the chat
    chats[chat_id] = nil

    -- Safe write back to metadata.lua
    local ok, err = safeWriteToMetadata(actual_doc_path, chats)
    if not ok then
        logger.warn("deleteChatFromDocSettings: " .. (err or "Write failed"))
        return false
    end

    -- Update chat index
    if stored_path and stored_path ~= "__GENERAL_CHATS__" then
        self:updateChatIndex(stored_path, "delete", chat_id, chats)
    end

    logger.info("Deleted chat from metadata.lua: " .. chat_id)
    return true
end

-- Update chat in metadata.lua (for rename, tags, etc.)
-- @param ui: ReaderUI object or nil
-- @param chat_id: Chat ID to update
-- @param updates: Table of fields to update
-- @param document_path: Document path (required if ui is nil or doesn't have document.file)
-- @return true on success, false on failure
function ChatHistoryManager:updateChatInDocSettings(ui, chat_id, updates, document_path)
    if not chat_id or not updates then
        logger.warn("updateChatInDocSettings: Missing chat_id or updates")
        return false
    end

    -- Extract document path from ui or use provided document_path
    local actual_doc_path = document_path
    if ui and ui.document and ui.document.file then
        actual_doc_path = ui.document.file
    end

    if not actual_doc_path then
        logger.warn("updateChatInDocSettings: Missing document_path")
        return false
    end

    -- Verify document exists
    if not lfs.attributes(actual_doc_path, "mode") then
        logger.warn("updateChatInDocSettings: Document not found: " .. actual_doc_path)
        return false
    end

    -- Read chats from metadata.lua
    local DocSettings = require("docsettings")
    local doc_settings = DocSettings:open(actual_doc_path)
    local chats = doc_settings:readSetting("koassistant_chats", {})

    -- Check if chat exists
    if not chats[chat_id] then
        logger.warn("updateChatInDocSettings: Chat not found: " .. chat_id)
        return false
    end

    -- Apply updates
    for key, value in pairs(updates) do
        chats[chat_id][key] = value
    end

    -- Safe write back to metadata.lua
    local ok, err = safeWriteToMetadata(actual_doc_path, chats)
    if not ok then
        logger.warn("updateChatInDocSettings: " .. (err or "Write failed"))
        return false
    end

    logger.info("Updated chat in metadata.lua: " .. chat_id)
    return true
end

--[[
    General chat storage methods (for chats without a document context)
--]]

-- Save general chat to dedicated settings file
-- @param chat_data: Complete chat data structure
-- @return chat_id on success, false on failure
function ChatHistoryManager:saveGeneralChat(chat_data)
    if not chat_data or not chat_data.id then
        logger.warn("saveGeneralChat: Missing chat_data or chat_data.id")
        return false
    end

    -- Open general chats file
    local settings = LuaSettings:open(self.GENERAL_CHAT_FILE)

    -- Read existing chats
    local chats = settings:readSetting("chats", {})

    -- Add or update this chat (keyed by ID)
    chats[chat_data.id] = chat_data

    -- Save back to file
    settings:saveSetting("chats", chats)
    settings:flush()

    logger.info("Saved general chat: " .. chat_data.id)
    return chat_data.id
end

-- Load all general chats from dedicated settings file
-- @return array of chat objects sorted by timestamp (newest first)
function ChatHistoryManager:getGeneralChats()
    -- Open general chats file
    local settings = LuaSettings:open(self.GENERAL_CHAT_FILE)

    -- Read chats table
    local chats_table = settings:readSetting("chats", {})

    -- Convert table to sorted array
    local chats = {}
    for chat_id, chat_data in pairs(chats_table) do
        table.insert(chats, chat_data)
    end

    -- Sort by timestamp (newest first)
    table.sort(chats, function(a, b)
        return (a.timestamp or 0) > (b.timestamp or 0)
    end)

    logger.info("Loaded " .. #chats .. " general chats")
    return chats
end

-- Get specific general chat by ID
-- @param chat_id: Chat ID to load
-- @return chat data or nil if not found
function ChatHistoryManager:getGeneralChatById(chat_id)
    if not chat_id then
        logger.warn("getGeneralChatById: Missing chat_id")
        return nil
    end

    -- Open general chats file
    local settings = LuaSettings:open(self.GENERAL_CHAT_FILE)

    -- Read chats table
    local chats = settings:readSetting("chats", {})

    return chats[chat_id]
end

-- Delete general chat by ID
-- @param chat_id: Chat ID to delete
-- @return true on success, false on failure
function ChatHistoryManager:deleteGeneralChat(chat_id)
    if not chat_id then
        logger.warn("deleteGeneralChat: Missing chat_id")
        return false
    end

    -- Open general chats file
    local settings = LuaSettings:open(self.GENERAL_CHAT_FILE)

    -- Read existing chats
    local chats = settings:readSetting("chats", {})

    -- Check if chat exists
    if not chats[chat_id] then
        logger.warn("deleteGeneralChat: Chat not found: " .. chat_id)
        return false
    end

    -- Delete the chat
    chats[chat_id] = nil

    -- Save back to file
    settings:saveSetting("chats", chats)
    settings:flush()

    logger.info("Deleted general chat: " .. chat_id)
    return true
end

-- Update general chat (for rename, tags, etc.)
-- @param chat_id: Chat ID to update
-- @param updates: Table of fields to update
-- @return true on success, false on failure
function ChatHistoryManager:updateGeneralChat(chat_id, updates)
    if not chat_id or not updates then
        logger.warn("updateGeneralChat: Missing chat_id or updates")
        return false
    end

    -- Open general chats file
    local settings = LuaSettings:open(self.GENERAL_CHAT_FILE)

    -- Read existing chats
    local chats = settings:readSetting("chats", {})

    -- Check if chat exists
    if not chats[chat_id] then
        logger.warn("updateGeneralChat: Chat not found: " .. chat_id)
        return false
    end

    -- Apply updates
    for key, value in pairs(updates) do
        chats[chat_id][key] = value
    end

    -- Save back to file
    settings:saveSetting("chats", chats)
    settings:flush()

    logger.info("Updated general chat: " .. chat_id)
    return true
end

--[[
    Multi-book chat storage (dedicated file for multi-book comparisons)
    Similar to general chats but for multi-book context
--]]

-- Save multi-book chat to dedicated settings file
-- @param chat_data: Chat object with id, title, messages, etc.
-- @return chat_id on success, false on failure
function ChatHistoryManager:saveMultiBookChat(chat_data)
    if not chat_data or not chat_data.id then
        logger.warn("saveMultiBookChat: Missing chat_data or chat_data.id")
        return false
    end

    -- Open multi-book chats file
    local settings = LuaSettings:open(self.MULTI_BOOK_CHAT_FILE)

    -- Read existing chats
    local chats = settings:readSetting("chats", {})

    -- Add or update this chat (keyed by ID)
    chats[chat_data.id] = chat_data

    -- Save back to file
    settings:saveSetting("chats", chats)
    settings:flush()

    logger.info("Saved multi-book chat: " .. chat_data.id)
    return chat_data.id
end

-- Load all multi-book chats from dedicated settings file
-- @return array of chat objects sorted by timestamp (newest first)
function ChatHistoryManager:getMultiBookChats()
    -- Open multi-book chats file
    local settings = LuaSettings:open(self.MULTI_BOOK_CHAT_FILE)

    -- Read chats table
    local chats_table = settings:readSetting("chats", {})

    -- Convert table to sorted array
    local chats = {}
    for chat_id, chat_data in pairs(chats_table) do
        table.insert(chats, chat_data)
    end

    -- Sort by timestamp (newest first)
    table.sort(chats, function(a, b)
        return (a.timestamp or 0) > (b.timestamp or 0)
    end)

    logger.info("Loaded " .. #chats .. " multi-book chats")
    return chats
end

-- Get specific multi-book chat by ID
-- @param chat_id: Chat ID to load
-- @return chat data or nil if not found
function ChatHistoryManager:getMultiBookChatById(chat_id)
    if not chat_id then
        logger.warn("getMultiBookChatById: Missing chat_id")
        return nil
    end

    -- Open multi-book chats file
    local settings = LuaSettings:open(self.MULTI_BOOK_CHAT_FILE)

    -- Read chats table
    local chats = settings:readSetting("chats", {})

    return chats[chat_id]
end

-- Delete multi-book chat by ID
-- @param chat_id: Chat ID to delete
-- @return true on success, false on failure
function ChatHistoryManager:deleteMultiBookChat(chat_id)
    if not chat_id then
        logger.warn("deleteMultiBookChat: Missing chat_id")
        return false
    end

    -- Open multi-book chats file
    local settings = LuaSettings:open(self.MULTI_BOOK_CHAT_FILE)

    -- Read existing chats
    local chats = settings:readSetting("chats", {})

    -- Check if chat exists
    if not chats[chat_id] then
        logger.warn("deleteMultiBookChat: Chat not found: " .. chat_id)
        return false
    end

    -- Delete the chat
    chats[chat_id] = nil

    -- Save back to file
    settings:saveSetting("chats", chats)
    settings:flush()

    logger.info("Deleted multi-book chat: " .. chat_id)
    return true
end

-- Update multi-book chat (for rename, tags, etc.)
-- @param chat_id: Chat ID to update
-- @param updates: Table of fields to update
-- @return true on success, false on failure
function ChatHistoryManager:updateMultiBookChat(chat_id, updates)
    if not chat_id or not updates then
        logger.warn("updateMultiBookChat: Missing chat_id or updates")
        return false
    end

    -- Open multi-book chats file
    local settings = LuaSettings:open(self.MULTI_BOOK_CHAT_FILE)

    -- Read existing chats
    local chats = settings:readSetting("chats", {})

    -- Check if chat exists
    if not chats[chat_id] then
        logger.warn("updateMultiBookChat: Chat not found: " .. chat_id)
        return false
    end

    -- Apply updates
    for key, value in pairs(updates) do
        chats[chat_id][key] = value
    end

    -- Save back to file
    settings:saveSetting("chats", chats)
    settings:flush()

    logger.info("Updated multi-book chat: " .. chat_id)
    return true
end

--[[
    Chat index maintenance for fast browsing

    The index stores lightweight metadata about which documents have chats:
    {
        ["/path/to/book.epub"] = {
            count = 3,
            last_modified = timestamp,
            chat_ids = {id1, id2, id3}
        }
    }
--]]

-- Update chat index when chats are saved/deleted
-- @param document_path: Document path
-- @param operation: "save" or "delete"
-- @param chat_id: Chat ID being saved/deleted
-- @param chats_table: Current chats table (for counting)
function ChatHistoryManager:updateChatIndex(document_path, operation, chat_id, chats_table)
    if not document_path or document_path == "__GENERAL_CHATS__" or document_path == "__MULTI_BOOK_CHATS__" then
        return
    end

    -- G_reader_settings is a global in KOReader
    local index = G_reader_settings:readSetting("koassistant_chat_index", {})

    -- Count chats in the provided table
    local count = 0
    local chat_ids = {}
    for id, chat in pairs(chats_table) do
        count = count + 1
        table.insert(chat_ids, id)
    end

    if count > 0 then
        -- Document has chats, update index entry
        index[document_path] = {
            count = count,
            last_modified = os.time(),
            chat_ids = chat_ids,
        }
    else
        -- No chats left, remove from index
        index[document_path] = nil
    end

    G_reader_settings:saveSetting("koassistant_chat_index", index)
    G_reader_settings:flush()

    logger.info("Updated chat index for: " .. document_path .. " (operation: " .. operation .. ", count: " .. count .. ")")
end

-- Get the chat index
-- @return table of document paths to chat metadata
function ChatHistoryManager:getChatIndex()
    -- G_reader_settings is a global in KOReader
    return G_reader_settings:readSetting("koassistant_chat_index", {})
end

-- Rebuild chat index by scanning .sdr folders (for recovery/maintenance)
-- @return count of documents indexed
function ChatHistoryManager:rebuildChatIndex()
    logger.info("Rebuilding chat index by scanning .sdr folders...")

    local DocSettings = require("docsettings")
    local index = {}
    local doc_count = 0

    -- Scan directory recursively for .sdr folders
    local function scanForSdrFolders(dir, depth)
        if depth > 4 then return end  -- Limit recursion depth

        local ok, iter = pcall(lfs.dir, dir)
        if not ok then return end

        for entry in iter do
            if entry ~= "." and entry ~= ".." and not entry:match("^%.") then
                local path = dir .. "/" .. entry
                local attr = lfs.attributes(path)

                if attr and attr.mode == "directory" then
                    if entry:match("%.sdr$") then
                        -- Found .sdr folder - check for corresponding book file
                        local book_path = path:gsub("%.sdr$", "")
                        if lfs.attributes(book_path, "mode") == "file" then
                            -- Read chats from metadata.lua
                            local doc_settings = DocSettings:open(book_path)
                            local chats = doc_settings:readSetting("koassistant_chats", {})

                            if chats and next(chats) then
                                -- Build index entry
                                local chat_ids = {}
                                local count = 0
                                for id in pairs(chats) do
                                    count = count + 1
                                    table.insert(chat_ids, id)
                                end

                                index[book_path] = {
                                    count = count,
                                    last_modified = os.time(),
                                    chat_ids = chat_ids,
                                }
                                doc_count = doc_count + 1
                                logger.info("Indexed: " .. book_path .. " (" .. count .. " chats)")
                            end
                        end
                    else
                        -- Recurse into subdirectory
                        scanForSdrFolders(path, depth + 1)
                    end
                end
            end
        end
    end

    -- Start scanning from KOReader data directory parent
    local start_dir = DataStorage:getDataDir() .. "/.."
    scanForSdrFolders(start_dir, 1)

    -- Save rebuilt index
    G_reader_settings:saveSetting("koassistant_chat_index", index)
    G_reader_settings:flush()

    logger.info("Chat index rebuilt: " .. doc_count .. " documents indexed")
    return doc_count
end

--[[
    Unified wrapper methods for UI compatibility

    These methods automatically route to v1 or v2 storage based on chat_storage_version.
    This allows UI code to remain unchanged while supporting both storage systems.
--]]

-- Unified method to get all documents with chats
-- @param ui: ReaderUI object (optional, only needed for v2 if opening specific book)
-- @return array of document objects with {path, title, author}
function ChatHistoryManager:getAllDocumentsUnified(ui)
    if self:useDocSettingsStorage() then
        -- v2/v3: Use chat index + general chats file
        local documents = {}
        local DocSettings = require("docsettings")

        -- Add general chats as a pseudo-document
        local general_chats = self:getGeneralChats()
        if #general_chats > 0 then
            table.insert(documents, {
                path = "__GENERAL_CHATS__",
                title = _("General AI Chats"),
                author = nil,
            })
        end

        -- Add multi-book chats as a pseudo-document
        local multi_book_chats = self:getMultiBookChats()
        if #multi_book_chats > 0 then
            table.insert(documents, {
                path = "__MULTI_BOOK_CHATS__",
                title = _("Multi-Book Chats"),
                author = nil,
            })
        end

        -- Add documents from chat index
        local index = self:getChatIndex()
        for doc_path, info in pairs(index) do
            if doc_path ~= "__GENERAL_CHATS__" then
                -- Check if document still exists at this path
                if lfs.attributes(doc_path, "mode") then
                    -- Try to get book metadata
                    local doc_settings = DocSettings:open(doc_path)
                    local doc_props = doc_settings:readSetting("doc_props")

                    local title = doc_props and doc_props.title or doc_path:match("([^/]+)$")
                    local author = doc_props and doc_props.authors or nil

                    table.insert(documents, {
                        path = doc_path,
                        title = title,
                        author = author,
                    })
                else
                    -- Path is stale (file moved or deleted)
                    -- Skip for now - will be fixed when user opens the document
                    logger.info("Skipping stale chat index path: " .. doc_path)
                end
            end
        end

        return documents
    else
        -- v1: Use existing method
        return self:getAllDocuments()
    end
end

-- Unified method to get chats for a document
-- @param ui: ReaderUI object (needed for v2 to access doc_settings)
-- @param document_path: Path to document or "__GENERAL_CHATS__"
-- @return array of chat objects sorted by timestamp (newest first)
function ChatHistoryManager:getChatsUnified(ui, document_path)
    if self:useDocSettingsStorage() then
        -- v2: Load from metadata.lua, general chats, or multi-book chats file
        if document_path == "__GENERAL_CHATS__" then
            return self:getGeneralChats()
        elseif document_path == "__MULTI_BOOK_CHATS__" then
            return self:getMultiBookChats()
        else
            -- Need to read chats from metadata.lua for the document
            local DocSettings = require("docsettings")
            if ui and ui.document and ui.document.file == document_path then
                -- Current document is open
                local chats = self:getChatsFromDocSettings(ui)

                -- Self-healing: Update index if it has stale path
                if #chats > 0 then
                    local doc_settings = DocSettings:open(document_path)
                    local chats_table = doc_settings:readSetting("koassistant_chats", {})
                    self:updateChatIndex(document_path, "refresh", nil, chats_table)
                end

                return chats
            elseif ui and ui.document and ui.document.file then
                -- Current document is open but path is different (from index)
                -- This means the file moved - update index with new path
                local chats = self:getChatsFromDocSettings(ui)

                if #chats > 0 then
                    local actual_path = ui.document.file
                    local doc_settings = DocSettings:open(actual_path)
                    local chats_table = doc_settings:readSetting("koassistant_chats", {})

                    -- Update index with actual path and remove stale entry
                    self:updateChatIndex(actual_path, "refresh", nil, chats_table)
                    if actual_path ~= document_path then
                        -- Remove stale path from index
                        -- G_reader_settings is a global in KOReader
                        local index = G_reader_settings:readSetting("koassistant_chat_index", {})
                        index[document_path] = nil
                        G_reader_settings:saveSetting("koassistant_chat_index", index)
                        G_reader_settings:flush()
                        logger.info("Updated chat index: " .. document_path .. " → " .. actual_path)
                    end
                end

                return chats
            else
                -- Document not currently open, read from metadata.lua manually
                if lfs.attributes(document_path, "mode") then
                    local doc_settings = DocSettings:open(document_path)
                    local chats_table = doc_settings:readSetting("koassistant_chats", {})

                    -- Convert table to sorted array
                    local chats = {}
                    for chat_id, chat_data in pairs(chats_table) do
                        table.insert(chats, chat_data)
                    end

                    -- Sort by timestamp (newest first)
                    table.sort(chats, function(a, b)
                        return (a.timestamp or 0) > (b.timestamp or 0)
                    end)

                    return chats
                else
                    logger.warn("Document not found: " .. document_path)
                    return {}
                end
            end
        end
    else
        -- v1: Use existing method
        return self:getChatsForDocument(document_path)
    end
end

return ChatHistoryManager