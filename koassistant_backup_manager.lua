local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")
local _ = require("koassistant_gettext")
local DocSettings = require("docsettings")
local JSON = require("json")

-- Get plugin directory by normalizing the path
local function getPluginDir()
    local data_dir = DataStorage:getDataDir()
    -- data_dir is typically: /path/to/koreader
    -- plugin_dir should be: /path/to/koreader/plugins/koassistant.koplugin
    -- Some KOReader installs use: /path/to/.adds/koreader
    -- In that case plugins are in: /path/to/.adds/koreader/../plugins/koassistant.koplugin

    -- Try direct path first (most common)
    local direct_path = data_dir .. "/plugins/koassistant.koplugin"
    if lfs.attributes(direct_path .. "/main.lua", "mode") == "file" then
        return direct_path
    end

    -- Try parent directory (e-reader installations)
    local parent_path = data_dir:gsub("/[^/]+$", "") .. "/plugins/koassistant.koplugin"
    if lfs.attributes(parent_path .. "/main.lua", "mode") == "file" then
        return parent_path
    end

    -- Fallback to current method (with ..)
    return data_dir .. "/../plugins/koassistant.koplugin"
end

local BackupManager = {
    BACKUP_DIR = DataStorage:getDataDir() .. "/koassistant_backups",
    BACKUP_VERSION = "1.0",
    PLUGIN_DIR = getPluginDir(),
    SETTINGS_DIR = DataStorage:getSettingsDir(),
    CHAT_DIR = DataStorage:getDataDir() .. "/koassistant_chats",
    RESTORE_POINT_RETENTION_DAYS = 7,
    LOCK_FILE = DataStorage:getDataDir() .. "/koassistant_backups/.backup_lock",
    LOCK_TIMEOUT = 300,  -- 5 minutes
}

function BackupManager:new()
    local manager = {}
    setmetatable(manager, self)
    self.__index = self

    -- Ensure backup directory exists
    self:_ensureBackupDirectory()

    -- Clean up stale temp directories and locks
    self:_cleanupStaleTempDirs()
    self:_cleanupStaleLocks()

    -- Log paths for debugging
    logger.dbg("BackupManager: PLUGIN_DIR =", self.PLUGIN_DIR)
    logger.dbg("BackupManager: Domains dir exists:", lfs.attributes(self.PLUGIN_DIR .. "/domains", "mode"))
    logger.dbg("BackupManager: Behaviors dir exists:", lfs.attributes(self.PLUGIN_DIR .. "/behaviors", "mode"))

    return manager
end

-- Ensure backup directory exists
function BackupManager:_ensureBackupDirectory()
    if not lfs.attributes(self.BACKUP_DIR, "mode") then
        logger.info("BackupManager: Creating backup directory: " .. self.BACKUP_DIR)
        lfs.mkdir(self.BACKUP_DIR)
    end
end

-- Sanitize path for shell command usage
-- CRITICAL: Prevents command injection via malicious filenames
function BackupManager:_sanitizePath(path)
    if not path then
        return nil, "Path is nil"
    end

    -- Check for dangerous characters that could enable command injection
    -- Double quotes, backticks, dollar signs, backslashes, semicolons
    if path:match('["`$\\;]') then
        logger.err("BackupManager: Dangerous characters detected in path:", path)
        return nil, "Path contains dangerous characters"
    end

    -- Check for command substitution patterns
    if path:match("$%(") or path:match("%$%{") then
        logger.err("BackupManager: Command substitution detected in path:", path)
        return nil, "Path contains command substitution"
    end

    return path
end

-- Acquire lock for backup/restore operations
function BackupManager:_acquireLock()
    -- Check if lock exists
    local lock_attr = lfs.attributes(self.LOCK_FILE, "mode")
    if lock_attr == "file" then
        -- Check if lock is stale (older than LOCK_TIMEOUT)
        local mtime = lfs.attributes(self.LOCK_FILE, "modification")
        if mtime and (os.time() - mtime < self.LOCK_TIMEOUT) then
            logger.warn("BackupManager: Another backup operation is in progress")
            return false, "Another backup or restore operation is in progress. Please wait."
        else
            logger.info("BackupManager: Removing stale lock file")
            os.remove(self.LOCK_FILE)
        end
    end

    -- Create lock file
    local lock_file = io.open(self.LOCK_FILE, "w")
    if not lock_file then
        logger.err("BackupManager: Failed to create lock file")
        return false, "Failed to acquire lock"
    end
    lock_file:write(tostring(os.time()))
    lock_file:close()

    logger.dbg("BackupManager: Lock acquired")
    return true
end

-- Release lock after backup/restore operation
function BackupManager:_releaseLock()
    if lfs.attributes(self.LOCK_FILE, "mode") == "file" then
        os.remove(self.LOCK_FILE)
        logger.dbg("BackupManager: Lock released")
    end
end

-- Clean up stale lock files (called on init)
function BackupManager:_cleanupStaleLocks()
    local lock_attr = lfs.attributes(self.LOCK_FILE, "mode")
    if lock_attr == "file" then
        local mtime = lfs.attributes(self.LOCK_FILE, "modification")
        if mtime and (os.time() - mtime > self.LOCK_TIMEOUT) then
            logger.info("BackupManager: Cleaning up stale lock file")
            os.remove(self.LOCK_FILE)
        end
    end
end

-- Clean up stale temporary directories (called on init)
function BackupManager:_cleanupStaleTempDirs()
    if not lfs.attributes(self.BACKUP_DIR, "mode") then
        return
    end

    local current_time = os.time()
    local TEMP_MAX_AGE = 3600  -- 1 hour

    for entry in lfs.dir(self.BACKUP_DIR) do
        if entry:match("^%.temp_") then
            local temp_path = self.BACKUP_DIR .. "/" .. entry
            local attr = lfs.attributes(temp_path, "mode")

            if attr == "directory" then
                local mtime = lfs.attributes(temp_path, "modification")
                if mtime and (current_time - mtime > TEMP_MAX_AGE) then
                    logger.info("BackupManager: Cleaning up stale temp directory:", entry)
                    -- Use sanitized path for cleanup
                    local safe_path, err = self:_sanitizePath(temp_path)
                    if safe_path then
                        os.execute(string.format('rm -rf "%s"', safe_path))
                    else
                        logger.err("BackupManager: Cannot clean temp dir - path sanitization failed:", err)
                    end
                end
            end
        end
    end
end

-- Safely remove temporary directory with sanitization
function BackupManager:_removeTempDir(temp_dir)
    local safe_temp, err = self:_sanitizePath(temp_dir)
    if safe_temp then
        os.execute(string.format('rm -rf "%s"', safe_temp))
    else
        logger.err("BackupManager: Cannot remove temp dir - path sanitization failed:", err)
    end
end

-- Generate timestamp string for filenames
function BackupManager:_getTimestamp()
    local now = os.date("*t")
    return string.format("%04d%02d%02d_%02d%02d%02d",
        now.year, now.month, now.day, now.hour, now.min, now.sec)
end

-- Get human-readable date string
function BackupManager:_getDateString(timestamp)
    if timestamp then
        local t = os.date("*t", timestamp)
        return os.date("%Y-%m-%d %H:%M:%S", timestamp)
    end
    return os.date("%Y-%m-%d %H:%M:%S")
end

-- Get directory size recursively
function BackupManager:_getDirectorySize(path)
    local total_size = 0

    if not lfs.attributes(path, "mode") then
        return 0
    end

    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local full_path = path .. "/" .. entry
            local attr = lfs.attributes(full_path)

            if attr then
                if attr.mode == "file" then
                    total_size = total_size + attr.size
                elseif attr.mode == "directory" then
                    total_size = total_size + self:_getDirectorySize(full_path)
                end
            end
        end
    end

    return total_size
end

-- Get file size
function BackupManager:_getFileSize(path)
    local attr = lfs.attributes(path)
    if attr and attr.mode == "file" then
        return attr.size
    end
    return 0
end

-- Format size in human-readable format
function BackupManager:_formatSize(bytes)
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.1f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    else
        return string.format("%.1f GB", bytes / (1024 * 1024 * 1024))
    end
end

-- Copy a single file
function BackupManager:_copyFile(src, dest)
    -- Sanitize paths before shell operation
    local safe_src, err_src = self:_sanitizePath(src)
    if not safe_src then
        logger.err("BackupManager: Source path sanitization failed:", err_src)
        return false, "Invalid source path: " .. err_src
    end

    local safe_dest, err_dest = self:_sanitizePath(dest)
    if not safe_dest then
        logger.err("BackupManager: Destination path sanitization failed:", err_dest)
        return false, "Invalid destination path: " .. err_dest
    end

    local success, err = os.execute(string.format('cp "%s" "%s"', safe_src, safe_dest))
    if not success then
        logger.warn("BackupManager: Failed to copy file: " .. src .. " -> " .. dest .. " : " .. (err or "unknown error"))
        return false
    end
    return true
end

-- Copy directory recursively
function BackupManager:_copyDirectory(src, dest, filter)
    -- Create destination directory
    if not lfs.attributes(dest, "mode") then
        local success, err = lfs.mkdir(dest)
        if not success then
            logger.err("BackupManager: Failed to create directory: " .. dest)
            return false, "Failed to create directory: " .. dest
        end
    end

    -- Copy files
    for entry in lfs.dir(src) do
        if entry ~= "." and entry ~= ".." then
            local src_path = src .. "/" .. entry
            local dest_path = dest .. "/" .. entry
            local attr = lfs.attributes(src_path)

            if attr then
                if attr.mode == "file" then
                    -- Apply filter if provided
                    if not filter or filter(entry, src_path) then
                        if not self:_copyFile(src_path, dest_path) then
                            return false, "Failed to copy file: " .. src_path
                        end
                    end
                elseif attr.mode == "directory" then
                    -- Recursively copy subdirectory
                    local success, err_msg = self:_copyDirectory(src_path, dest_path, filter)
                    if not success then
                        return false, err_msg
                    end
                end
            end
        end
    end

    return true
end

-- Create tar.gz archive
function BackupManager:_createArchive(source_dir, archive_path)
    -- Sanitize paths before shell operation
    local safe_source, err_source = self:_sanitizePath(source_dir)
    if not safe_source then
        logger.err("BackupManager: Source directory sanitization failed:", err_source)
        return false, "Invalid source directory: " .. err_source
    end

    local safe_archive, err_archive = self:_sanitizePath(archive_path)
    if not safe_archive then
        logger.err("BackupManager: Archive path sanitization failed:", err_archive)
        return false, "Invalid archive path: " .. err_archive
    end

    -- Use tar to create compressed archive
    -- -czf: create, compress with gzip, file
    -- -C: change to directory
    local cmd = string.format('cd "%s" && tar -czf "%s" .', safe_source, safe_archive)
    local success, exit_type, exit_code = os.execute(cmd)

    if not success or (exit_type == "exit" and exit_code ~= 0) then
        logger.err("BackupManager: Failed to create archive: " .. archive_path)
        return false, "Failed to create archive (tar command failed)"
    end

    return true
end

-- Extract tar.gz archive (can extract specific files or all files)
function BackupManager:_extractArchive(archive_path, dest_dir, specific_file)
    -- Sanitize paths before shell operation
    local safe_archive, err_archive = self:_sanitizePath(archive_path)
    if not safe_archive then
        logger.err("BackupManager: Archive path sanitization failed:", err_archive)
        return false, "Invalid archive path: " .. err_archive
    end

    local safe_dest, err_dest = self:_sanitizePath(dest_dir)
    if not safe_dest then
        logger.err("BackupManager: Destination directory sanitization failed:", err_dest)
        return false, "Invalid destination directory: " .. err_dest
    end

    -- Ensure destination directory exists
    if not lfs.attributes(dest_dir, "mode") then
        local success, err = lfs.mkdir(dest_dir)
        if not success then
            return false, "Failed to create extraction directory: " .. dest_dir
        end
    end

    -- Use tar to extract
    -- -xzf: extract, uncompress with gzip, file
    -- -C: change to directory
    -- specific_file: optional, extract only this file (e.g., "manifest.json")
    local cmd
    if specific_file then
        cmd = string.format('tar -xzf "%s" -C "%s" "%s" 2>&1', safe_archive, safe_dest, specific_file)
    else
        cmd = string.format('tar -xzf "%s" -C "%s"', safe_archive, safe_dest)
    end

    local success, exit_type, exit_code = os.execute(cmd)

    if not success or (exit_type == "exit" and exit_code ~= 0) then
        logger.err("BackupManager: Failed to extract archive: " .. archive_path)
        return false, "Failed to extract archive (tar command failed)"
    end

    return true
end

-- Simple JSON encoder (basic implementation for our needs)
function BackupManager:_encodeJSON(obj, indent)
    indent = indent or 0
    local indent_str = string.rep("  ", indent)
    local next_indent_str = string.rep("  ", indent + 1)

    if type(obj) == "table" then
        local is_array = true
        local count = 0
        for k, v in pairs(obj) do
            count = count + 1
            if type(k) ~= "number" or k ~= count then
                is_array = false
                break
            end
        end

        if is_array then
            -- Array
            local parts = {}
            for i, v in ipairs(obj) do
                table.insert(parts, next_indent_str .. self:_encodeJSON(v, indent + 1))
            end
            if #parts == 0 then
                return "[]"
            end
            return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent_str .. "]"
        else
            -- Object
            local parts = {}
            for k, v in pairs(obj) do
                local key = string.format('"%s"', tostring(k))
                table.insert(parts, next_indent_str .. key .. ": " .. self:_encodeJSON(v, indent + 1))
            end
            if #parts == 0 then
                return "{}"
            end
            return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent_str .. "}"
        end
    elseif type(obj) == "string" then
        -- Escape special characters
        local escaped = obj:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
        return '"' .. escaped .. '"'
    elseif type(obj) == "number" then
        return tostring(obj)
    elseif type(obj) == "boolean" then
        return obj and "true" or "false"
    elseif obj == nil then
        return "null"
    else
        return '""'
    end
end

-- Simple JSON decoder (basic implementation for our needs)
function BackupManager:_decodeJSON(json_str)
    -- Remove whitespace
    json_str = json_str:gsub("^%s+", ""):gsub("%s+$", "")

    -- Parse value
    local function parse_value(str, pos)
        pos = pos or 1
        -- Skip whitespace
        while pos <= #str and str:sub(pos, pos):match("%s") do
            pos = pos + 1
        end

        if pos > #str then
            return nil, pos
        end

        local char = str:sub(pos, pos)

        -- Object
        if char == "{" then
            local obj = {}
            pos = pos + 1

            -- Skip whitespace
            while pos <= #str and str:sub(pos, pos):match("%s") do
                pos = pos + 1
            end

            if str:sub(pos, pos) == "}" then
                return obj, pos + 1
            end

            while pos <= #str do
                -- Parse key
                local key
                key, pos = parse_value(str, pos)

                -- Skip whitespace and colon
                while pos <= #str and (str:sub(pos, pos):match("%s") or str:sub(pos, pos) == ":") do
                    pos = pos + 1
                end

                -- Parse value
                local value
                value, pos = parse_value(str, pos)

                obj[key] = value

                -- Skip whitespace
                while pos <= #str and str:sub(pos, pos):match("%s") do
                    pos = pos + 1
                end

                -- Check for comma or end
                if str:sub(pos, pos) == "," then
                    pos = pos + 1
                elseif str:sub(pos, pos) == "}" then
                    return obj, pos + 1
                else
                    break
                end
            end

            return obj, pos

        -- Array
        elseif char == "[" then
            local arr = {}
            pos = pos + 1

            -- Skip whitespace
            while pos <= #str and str:sub(pos, pos):match("%s") do
                pos = pos + 1
            end

            if str:sub(pos, pos) == "]" then
                return arr, pos + 1
            end

            while pos <= #str do
                local value
                value, pos = parse_value(str, pos)
                table.insert(arr, value)

                -- Skip whitespace
                while pos <= #str and str:sub(pos, pos):match("%s") do
                    pos = pos + 1
                end

                -- Check for comma or end
                if str:sub(pos, pos) == "," then
                    pos = pos + 1
                elseif str:sub(pos, pos) == "]" then
                    return arr, pos + 1
                else
                    break
                end
            end

            return arr, pos

        -- String
        elseif char == '"' then
            pos = pos + 1
            local start_pos = pos
            local escaped = false

            while pos <= #str do
                char = str:sub(pos, pos)
                if escaped then
                    escaped = false
                elseif char == "\\" then
                    escaped = true
                elseif char == '"' then
                    local value = str:sub(start_pos, pos - 1)
                    -- Unescape
                    value = value:gsub('\\\\', '\\'):gsub('\\"', '"'):gsub('\\n', '\n'):gsub('\\r', '\r'):gsub('\\t', '\t')
                    return value, pos + 1
                end
                pos = pos + 1
            end

            return str:sub(start_pos, pos - 1), pos

        -- Number
        elseif char:match("[%d%-]") then
            local start_pos = pos
            while pos <= #str and str:sub(pos, pos):match("[%d%.eE%+%-]") do
                pos = pos + 1
            end
            local num_str = str:sub(start_pos, pos - 1)
            return tonumber(num_str), pos

        -- Boolean or null
        elseif str:sub(pos, pos + 3) == "true" then
            return true, pos + 4
        elseif str:sub(pos, pos + 4) == "false" then
            return false, pos + 5
        elseif str:sub(pos, pos + 3) == "null" then
            return nil, pos + 4
        end

        return nil, pos
    end

    local value, _ = parse_value(json_str, 1)
    return value
end

-- Create manifest file
function BackupManager:_createManifest(options, counts)
    -- Get plugin version from _meta.lua
    local plugin_version = "unknown"
    local success, meta = pcall(dofile, self.PLUGIN_DIR .. "/_meta.lua")
    if success and meta and meta.version then
        plugin_version = meta.version
    end

    local timestamp = os.time()
    local manifest = {
        version = self.BACKUP_VERSION,
        plugin_version = plugin_version,
        timestamp = timestamp,
        created_date = self:_getDateString(timestamp),
        contents = {
            settings = options.include_settings or false,
            api_keys = options.include_api_keys or false,
            config_files = options.include_configs or false,
            domains = options.include_content or false,
            behaviors = options.include_content or false,
            chats = options.include_chats or false,
        },
        counts = counts or {},
        settings_schema_version = "2",
        notes = options.notes or "",
    }

    return self:_encodeJSON(manifest)
end

-- Parse manifest file
function BackupManager:_parseManifest(manifest_text)
    local success, manifest = pcall(function()
        return self:_decodeJSON(manifest_text)
    end)

    if not success or not manifest then
        logger.err("BackupManager: Failed to parse manifest")
        return nil, "Invalid or corrupted manifest file"
    end

    return manifest
end

-- Count items for manifest
function BackupManager:_countItems(options)
    local counts = {}

    -- Count domains
    if options.include_content then
        local domains_dir = self.PLUGIN_DIR .. "/domains"
        if lfs.attributes(domains_dir, "mode") == "directory" then
            local count = 0
            for entry in lfs.dir(domains_dir) do
                if entry ~= "." and entry ~= ".." and (entry:match("%.md$") or entry:match("%.txt$")) then
                    count = count + 1
                end
            end
            counts.domains = count
        else
            counts.domains = 0
        end

        -- Count behaviors
        local behaviors_dir = self.PLUGIN_DIR .. "/behaviors"
        if lfs.attributes(behaviors_dir, "mode") == "directory" then
            local count = 0
            for entry in lfs.dir(behaviors_dir) do
                if entry ~= "." and entry ~= ".." and (entry:match("%.md$") or entry:match("%.txt$")) then
                    count = count + 1
                end
            end
            counts.behaviors = count
        else
            counts.behaviors = 0
        end
    end

    -- Count chats
    if options.include_chats then
        local total_chats = 0

        local ChatHistoryManager = require("koassistant_chat_history_manager")
        local chat_manager = ChatHistoryManager:new()

        if chat_manager:useDocSettingsStorage() then
            -- v2: Count from chat index and general chats
            local chat_index = chat_manager:getChatIndex()

            for doc_path, info in pairs(chat_index) do
                total_chats = total_chats + (info.count or 0)
            end

            -- Add general chats
            local general_chats = chat_manager:getGeneralChats()
            total_chats = total_chats + #general_chats

            -- Add multi-book chats
            local multi_book_chats = chat_manager:getMultiBookChats()
            total_chats = total_chats + #multi_book_chats

            logger.dbg("BackupManager: Counted", total_chats, "chats (v2 storage)")
        else
            -- v1: Count from CHAT_DIR directory
            if lfs.attributes(self.CHAT_DIR, "mode") == "directory" then
                for doc_hash in lfs.dir(self.CHAT_DIR) do
                    if doc_hash ~= "." and doc_hash ~= ".." then
                        local doc_dir = self.CHAT_DIR .. "/" .. doc_hash
                        if lfs.attributes(doc_dir, "mode") == "directory" then
                            for entry in lfs.dir(doc_dir) do
                                if entry ~= "." and entry ~= ".." and not entry:match("%.old$") then
                                    total_chats = total_chats + 1
                                end
                            end
                        end
                    end
                end
            end

            logger.dbg("BackupManager: Counted", total_chats, "chats (v1 storage)")
        end

        counts.chats = total_chats
    end

    -- Count custom providers, models, behaviors from settings
    if options.include_settings then
        local settings = LuaSettings:open(self.SETTINGS_DIR .. "/koassistant_settings.lua")
        local features = settings:readSetting("features") or {}

        counts.custom_providers = 0
        if features.custom_providers then
            counts.custom_providers = #features.custom_providers
        end

        counts.custom_models = 0
        if features.custom_models then
            for provider, models in pairs(features.custom_models) do
                counts.custom_models = counts.custom_models + #models
            end
        end

        counts.custom_behaviors = 0
        if features.custom_behaviors then
            for _, _ in pairs(features.custom_behaviors) do
                counts.custom_behaviors = counts.custom_behaviors + 1
            end
        end
    end

    return counts
end

-- Export all chats to a table structure (for v2 JSON backup)
-- Returns a table mapping document paths to their chats and metadata
function BackupManager:exportAllChatsToTable()
    local ChatHistoryManager = require("koassistant_chat_history_manager")
    local chat_manager = ChatHistoryManager:new()

    -- Check if using DocSettings storage
    if not chat_manager:useDocSettingsStorage() then
        logger.warn("BackupManager: exportAllChatsToTable called but not using v2 storage")
        return {}
    end

    local all_chats = {}

    -- Read chat index to find all documents with chats
    local chat_index = chat_manager:getChatIndex()

    -- Export document chats
    for doc_path, index_info in pairs(chat_index) do
        -- Check if document still exists
        if lfs.attributes(doc_path, "mode") then
            local success, doc_settings = pcall(DocSettings.open, doc_path)
            if success and doc_settings then
                local chats = doc_settings:readSetting("koassistant_chats", {})

                if next(chats) then
                    -- Get book metadata
                    local doc_props = doc_settings:readSetting("doc_props") or {}

                    all_chats[doc_path] = {
                        chats = chats,
                        book_title = doc_props.title or "",
                        book_author = doc_props.authors or "",
                        chat_count = index_info.count or 0,
                    }

                    logger.dbg("BackupManager: Exported", index_info.count, "chats from", doc_path)
                end
            else
                logger.warn("BackupManager: Could not open DocSettings for", doc_path)
            end
        else
            logger.dbg("BackupManager: Skipping missing document", doc_path)
        end
    end

    -- Export general chats (chats not tied to a specific document)
    local general_chats = chat_manager:getGeneralChats()
    if #general_chats > 0 then
        -- Convert array to table keyed by ID (matching DocSettings format)
        local general_chats_table = {}
        for _, chat in ipairs(general_chats) do
            general_chats_table[chat.id] = chat
        end

        all_chats["__GENERAL_CHATS__"] = {
            chats = general_chats_table,
            book_title = "",
            book_author = "",
            chat_count = #general_chats,
        }

        logger.dbg("BackupManager: Exported", #general_chats, "general chats")
    end

    -- Export multi-book chats (chats comparing multiple books)
    local multi_book_chats = chat_manager:getMultiBookChats()
    if #multi_book_chats > 0 then
        -- Convert array to table keyed by ID (matching DocSettings format)
        local multi_book_chats_table = {}
        for _idx, chat in ipairs(multi_book_chats) do
            multi_book_chats_table[chat.id] = chat
        end

        all_chats["__MULTI_BOOK_CHATS__"] = {
            chats = multi_book_chats_table,
            book_title = "",
            book_author = "",
            chat_count = #multi_book_chats,
        }

        logger.dbg("BackupManager: Exported", #multi_book_chats, "multi-book chats")
    end

    return all_chats
end

-- Create backup
function BackupManager:createBackup(options)
    -- Validate options
    options = options or {}
    if not options.include_settings and not options.include_configs and not options.include_content and not options.include_chats then
        return { success = false, error = "No backup options selected" }
    end

    -- Acquire lock to prevent concurrent backups (unless skip_lock is set for internal calls)
    if not options.skip_lock then
        local lock_acquired, lock_err = self:_acquireLock()
        if not lock_acquired then
            return { success = false, error = lock_err }
        end
    end

    -- Create temporary directory for staging (with random suffix to prevent collisions)
    local timestamp = self:_getTimestamp()
    local random_suffix = tostring(math.random(100000, 999999))
    local temp_dir = self.BACKUP_DIR .. "/.temp_" .. timestamp .. "_" .. random_suffix
    local backup_name = "koassistant_backup_" .. timestamp .. ".koa"
    local backup_path = self.BACKUP_DIR .. "/" .. backup_name

    -- Create temp directory
    if not lfs.attributes(temp_dir, "mode") then
        local success, err = lfs.mkdir(temp_dir)
        if not success then
            if not options.skip_lock then
                self:_releaseLock()
            end
            return { success = false, error = "Failed to create temporary directory: " .. (err or "unknown error") }
        end
    end

    -- Count items for manifest
    local counts = self:_countItems(options)

    -- Copy settings (always include, excluding API keys if requested)
    if options.include_settings then
        local settings_dir = temp_dir .. "/settings"
        lfs.mkdir(settings_dir)

        local settings_file = self.SETTINGS_DIR .. "/koassistant_settings.lua"
        if lfs.attributes(settings_file, "mode") == "file" then
            if options.include_api_keys then
                -- Copy settings as-is
                self:_copyFile(settings_file, settings_dir .. "/koassistant_settings.lua")
            else
                -- Copy settings but remove API keys
                local settings = LuaSettings:open(settings_file)
                local features = settings:readSetting("features") or {}

                -- Save API keys for later restoration
                local api_keys = features.api_keys

                -- Remove API keys temporarily
                features.api_keys = nil

                -- Save modified settings to temp location
                local temp_settings = LuaSettings:open(settings_dir .. "/koassistant_settings.lua")
                temp_settings:saveSetting("features", features)

                -- Copy other top-level settings
                for key, value in pairs(settings.data) do
                    if key ~= "features" then
                        temp_settings:saveSetting(key, value)
                    end
                end

                temp_settings:flush()

                -- Restore API keys in original settings (don't modify user's settings)
                -- No need to restore since we're just reading
            end
        end
    end

    -- Copy config files
    if options.include_configs then
        local configs_dir = temp_dir .. "/configs"
        lfs.mkdir(configs_dir)

        -- Copy apikeys.lua if exists and if API keys included
        if options.include_api_keys then
            local apikeys_file = self.PLUGIN_DIR .. "/apikeys.lua"
            if lfs.attributes(apikeys_file, "mode") == "file" then
                self:_copyFile(apikeys_file, configs_dir .. "/apikeys.lua")
            end
        end

        -- Copy configuration.lua if exists
        local config_file = self.PLUGIN_DIR .. "/configuration.lua"
        if lfs.attributes(config_file, "mode") == "file" then
            self:_copyFile(config_file, configs_dir .. "/configuration.lua")
        end

        -- Copy custom_actions.lua if exists
        local custom_actions_file = self.PLUGIN_DIR .. "/custom_actions.lua"
        if lfs.attributes(custom_actions_file, "mode") == "file" then
            self:_copyFile(custom_actions_file, configs_dir .. "/custom_actions.lua")
        end
    end

    -- Copy user content (domains and behaviors)
    if options.include_content then
        -- Copy domains folder
        local domains_dir = self.PLUGIN_DIR .. "/domains"
        if lfs.attributes(domains_dir, "mode") == "directory" then
            local dest_domains = temp_dir .. "/domains"
            local success, err_msg = self:_copyDirectory(domains_dir, dest_domains, function(entry, path)
                -- Only copy .md and .txt files
                return entry:match("%.md$") or entry:match("%.txt$")
            end)
            if not success then
                -- Clean up and return error
                self:_removeTempDir(temp_dir)
                if not options.skip_lock then
                    self:_releaseLock()
                end
                return { success = false, error = err_msg }
            end
        end

        -- Copy behaviors folder
        local behaviors_dir = self.PLUGIN_DIR .. "/behaviors"
        if lfs.attributes(behaviors_dir, "mode") == "directory" then
            local dest_behaviors = temp_dir .. "/behaviors"
            local success, err_msg = self:_copyDirectory(behaviors_dir, dest_behaviors, function(entry, path)
                -- Only copy .md and .txt files
                return entry:match("%.md$") or entry:match("%.txt$")
            end)
            if not success then
                -- Clean up and return error
                self:_removeTempDir(temp_dir)
                if not options.skip_lock then
                    self:_releaseLock()
                end
                return { success = false, error = err_msg }
            end
        end
    end

    -- Backup chat history
    if options.include_chats then
        local ChatHistoryManager = require("koassistant_chat_history_manager")
        local chat_manager = ChatHistoryManager:new()

        if chat_manager:useDocSettingsStorage() then
            -- v2: Export chats to JSON
            local all_chats = self:exportAllChatsToTable()

            if next(all_chats) then
                local json_path = temp_dir .. "/koassistant_chats.json"
                local success, json_string = pcall(JSON.encode, all_chats)

                if not success then
                    self:_removeTempDir(temp_dir)
                    if not options.skip_lock then
                        self:_releaseLock()
                    end
                    return { success = false, error = "Failed to encode chats to JSON: " .. tostring(json_string) }
                end

                local file = io.open(json_path, "w")
                if not file then
                    self:_removeTempDir(temp_dir)
                    if not options.skip_lock then
                        self:_releaseLock()
                    end
                    return { success = false, error = "Failed to create chat JSON file" }
                end

                file:write(json_string)
                file:close()

                logger.info("BackupManager: Exported chats to JSON (v2 storage)")
            else
                logger.info("BackupManager: No chats to backup (v2 storage)")
            end
        else
            -- v1: Copy legacy CHAT_DIR directory
            if lfs.attributes(self.CHAT_DIR, "mode") == "directory" then
                local dest_chats = temp_dir .. "/chats"
                local success, err_msg = self:_copyDirectory(self.CHAT_DIR, dest_chats, function(entry, path)
                    -- Skip .old backup files
                    return not entry:match("%.old$")
                end)
                if not success then
                    -- Clean up and return error
                    self:_removeTempDir(temp_dir)
                    if not options.skip_lock then
                        self:_releaseLock()
                    end
                    return { success = false, error = err_msg }
                end

                logger.info("BackupManager: Backed up chats directory (v1 storage)")
            end
        end
    end

    -- Create manifest
    local manifest_json = self:_createManifest(options, counts)
    local manifest_file = io.open(temp_dir .. "/manifest.json", "w")
    if not manifest_file then
        self:_removeTempDir(temp_dir)
        if not options.skip_lock then
            self:_releaseLock()
        end
        return { success = false, error = "Failed to create manifest file" }
    end
    manifest_file:write(manifest_json)
    manifest_file:close()

    -- Create archive
    local success, err_msg = self:_createArchive(temp_dir, backup_path)
    if not success then
        -- Clean up and return error
        self:_removeTempDir(temp_dir)
        if not options.skip_lock then
            self:_releaseLock()
        end
        return { success = false, error = err_msg }
    end

    -- Clean up temp directory
    self:_removeTempDir(temp_dir)

    -- Release lock (only if we acquired it)
    if not options.skip_lock then
        self:_releaseLock()
    end

    -- Get backup size
    local backup_size = self:_getFileSize(backup_path)

    logger.info("BackupManager: Created backup: " .. backup_path .. " (" .. self:_formatSize(backup_size) .. ")")

    return {
        success = true,
        backup_path = backup_path,
        backup_name = backup_name,
        size = backup_size,
        counts = counts,
    }
end

-- Validate backup file (optimized to extract only manifest.json)
function BackupManager:validateBackup(backup_path)
    -- Check if file exists
    if not lfs.attributes(backup_path, "mode") then
        return { valid = false, errors = { "Backup file does not exist" } }
    end

    -- Create temp directory for extraction (with random suffix to avoid collisions)
    local random_suffix = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
    local temp_dir = self.BACKUP_DIR .. "/.temp_validate_" .. random_suffix

    -- OPTIMIZATION: Extract only manifest.json, not entire archive
    local success, err_msg = self:_extractArchive(backup_path, temp_dir, "manifest.json")

    if not success then
        return { valid = false, errors = { err_msg } }
    end

    -- Read and parse manifest
    local manifest_file = io.open(temp_dir .. "/manifest.json", "r")
    if not manifest_file then
        -- Clean up and return error
        local safe_temp, _ = self:_sanitizePath(temp_dir)
        if safe_temp then
            os.execute(string.format('rm -rf "%s"', safe_temp))
        end
        return { valid = false, errors = { "Manifest file not found in backup" } }
    end

    local manifest_text = manifest_file:read("*a")
    manifest_file:close()

    local manifest, parse_err = self:_parseManifest(manifest_text)
    if not manifest then
        -- Clean up and return error
        local safe_temp, _ = self:_sanitizePath(temp_dir)
        if safe_temp then
            os.execute(string.format('rm -rf "%s"', safe_temp))
        end
        return { valid = false, errors = { parse_err } }
    end

    -- Clean up temp directory
    local safe_temp, _ = self:_sanitizePath(temp_dir)
    if safe_temp then
        os.execute(string.format('rm -rf "%s"', safe_temp))
    end

    -- Check version compatibility
    local warnings = {}
    if manifest.plugin_version then
        -- Get current plugin version
        local current_version = "unknown"
        local pcall_ok, meta = pcall(dofile, self.PLUGIN_DIR .. "/_meta.lua")
        if pcall_ok and meta and meta.version then
            current_version = meta.version
        end

        -- Simple version comparison (would need more sophisticated logic for production)
        -- For now, just warn if versions differ
        if manifest.plugin_version ~= current_version then
            table.insert(warnings, "Backup was created with a different plugin version (" .. manifest.plugin_version .. ")")
        end
    end

    return {
        valid = true,
        manifest = manifest,
        warnings = warnings,
        errors = {},
    }
end

-- Validate action overrides against current actions
function BackupManager:_validateActionOverrides(overrides)
    if not overrides or type(overrides) ~= "table" then
        return {}, {}
    end

    local valid_overrides = {}
    local warnings = {}

    -- Load actions module to check if actions exist
    local success, Actions = pcall(require, "prompts.actions")
    if not success then
        logger.warn("BackupManager: Could not load actions module for validation")
        -- If we can't load actions, keep all overrides
        return overrides, {}
    end

    for action_id, override_config in pairs(overrides) do
        -- Action IDs in overrides can have context prefixes like "highlight:action_name"
        -- Strip the context prefix to check if the base action exists
        local base_action_id = action_id:match("^[^:]+:(.+)$") or action_id

        -- Search for the action in nested context tables
        local base_action = nil

        -- Define context tables to search (actions are nested under these)
        local context_tables = {
            Actions.highlight,
            Actions.book,
            Actions.multi_book,
            Actions.general,
            Actions.special,
        }

        -- First try: check by table key in each context
        for _idx, context_table in ipairs(context_tables) do
            if type(context_table) == "table" and context_table[base_action_id] then
                base_action = context_table[base_action_id]
                break
            end
        end

        -- Second try: check by ID field in each context
        if not base_action then
            for _idx, context_table in ipairs(context_tables) do
                if type(context_table) == "table" then
                    for _key, action in pairs(context_table) do
                        if type(action) == "table" and action.id == base_action_id then
                            base_action = action
                            break
                        end
                    end
                    if base_action then
                        break
                    end
                end
            end
        end

        if base_action then
            -- Action exists, keep the override
            valid_overrides[action_id] = override_config
        else
            -- Action no longer exists, skip and warn
            table.insert(warnings, string.format("Skipped override for missing action: %s", action_id))
            logger.warn("BackupManager: Skipped override for missing action:", action_id)
        end
    end

    return valid_overrides, warnings
end

-- Validate custom actions
function BackupManager:_validateCustomActions(custom_actions)
    if not custom_actions or type(custom_actions) ~= "table" then
        return {}, {}
    end

    local valid_actions = {}
    local warnings = {}

    for action_id, action_config in pairs(custom_actions) do
        -- Basic validation: check required fields
        -- Custom actions can have either:
        -- - text + prompt (standard custom actions)
        -- - text + template (legacy format, if any exist)
        if type(action_config) == "table" and action_config.text and (action_config.prompt or action_config.template) then
            valid_actions[action_id] = action_config
        else
            table.insert(warnings, string.format("Skipped invalid custom action: %s", action_id))
            logger.warn("BackupManager: Skipped invalid custom action:", action_id)
        end
    end

    return valid_actions, warnings
end

-- Create restore point before restoring
function BackupManager:createRestorePoint()
    logger.info("BackupManager: Creating restore point")

    -- Create backup of current state
    -- NOTE: skip_lock is true because this is always called from within restoreBackup()
    -- which has already acquired the lock
    local options = {
        include_settings = true,
        include_api_keys = true,
        include_configs = true,
        include_content = true,
        include_chats = false,  -- Don't include chats in restore points
        notes = "Automatic restore point",
        skip_lock = true,  -- Don't try to acquire lock (already held by caller)
    }

    local result = self:createBackup(options)
    if not result.success then
        return result
    end

    -- Rename to indicate it's a restore point
    local restore_point_name = result.backup_name:gsub("^koassistant_backup_", "koassistant_restore_point_")
    local restore_point_path = self.BACKUP_DIR .. "/" .. restore_point_name

    -- Sanitize paths before mv operation
    local safe_src, err_src = self:_sanitizePath(result.backup_path)
    local safe_dest, err_dest = self:_sanitizePath(restore_point_path)

    if safe_src and safe_dest then
        os.execute(string.format('mv "%s" "%s"', safe_src, safe_dest))
    else
        logger.err("BackupManager: Path sanitization failed for mv:", err_src or err_dest)
        return { success = false, error = "Failed to rename backup to restore point" }
    end

    logger.info("BackupManager: Created restore point: " .. restore_point_name)

    return {
        success = true,
        backup_path = restore_point_path,
        backup_name = restore_point_name,
    }
end

-- Restore chats from JSON backup (v2 storage)
-- @param json_path Path to koassistant_chats.json file
-- @param merge_mode If true, merge with existing chats; if false, replace
-- @return success, error_message
function BackupManager:restoreChatsFromJSON(json_path, merge_mode)
    local ChatHistoryManager = require("koassistant_chat_history_manager")
    local chat_manager = ChatHistoryManager:new()

    -- Read JSON file
    local file = io.open(json_path, "r")
    if not file then
        return false, "Failed to open chat JSON file: " .. json_path
    end

    local content = file:read("*all")
    file:close()

    -- Decode JSON
    local success, all_chats = pcall(JSON.decode, content)
    if not success then
        return false, "Failed to decode chat JSON: " .. tostring(all_chats)
    end

    local restored_count = 0
    local skipped_count = 0

    -- Restore chats for each document
    for doc_path, data in pairs(all_chats) do
        if doc_path == "__GENERAL_CHATS__" then
            -- Restore general chats
            local settings = LuaSettings:open(chat_manager.GENERAL_CHAT_FILE)
            local existing_chats = merge_mode and settings:readSetting("chats", {}) or {}

            -- Merge or replace
            for chat_id, chat_data in pairs(data.chats) do
                existing_chats[chat_id] = chat_data
                restored_count = restored_count + 1
            end

            settings:saveSetting("chats", existing_chats)
            settings:flush()

            logger.info("BackupManager: Restored", data.chat_count, "general chats")
        elseif doc_path == "__MULTI_BOOK_CHATS__" then
            -- Restore multi-book chats
            local settings = LuaSettings:open(chat_manager.MULTI_BOOK_CHAT_FILE)
            local existing_chats = merge_mode and settings:readSetting("chats", {}) or {}

            -- Merge or replace
            for chat_id, chat_data in pairs(data.chats) do
                existing_chats[chat_id] = chat_data
                restored_count = restored_count + 1
            end

            settings:saveSetting("chats", existing_chats)
            settings:flush()

            logger.info("BackupManager: Restored", data.chat_count, "multi-book chats")
        else
            -- Restore document-specific chats
            -- Check if document exists
            if lfs.attributes(doc_path, "mode") then
                local doc_settings = DocSettings:open(doc_path)

                -- Get existing chats (for merge mode)
                local existing_chats = merge_mode and doc_settings:readSetting("koassistant_chats", {}) or {}

                -- Merge or replace
                for chat_id, chat_data in pairs(data.chats) do
                    existing_chats[chat_id] = chat_data
                    restored_count = restored_count + 1
                end

                -- Save back to doc_settings
                doc_settings:saveSetting("koassistant_chats", existing_chats)
                doc_settings:flush()

                -- Update chat index
                chat_manager:updateChatIndex(doc_path, "restore", nil, existing_chats)

                logger.info("BackupManager: Restored", data.chat_count, "chats to", doc_path)
            else
                -- Document doesn't exist on this device, skip
                logger.warn("BackupManager: Skipping chats for missing document:", doc_path)
                skipped_count = skipped_count + (data.chat_count or 0)
            end
        end
    end

    logger.info("BackupManager: Restored", restored_count, "chats,", skipped_count, "skipped (missing documents)")
    return true, nil
end

-- Restore from backup (with atomic rollback on failure)
function BackupManager:restoreBackup(backup_path, options)
    options = options or {}

    -- Acquire lock to prevent concurrent operations
    local lock_acquired, lock_err = self:_acquireLock()
    if not lock_acquired then
        return { success = false, error = lock_err }
    end

    -- Validate backup first
    local validation = self:validateBackup(backup_path)
    if not validation.valid then
        self:_releaseLock()
        return {
            success = false,
            error = "Backup validation failed: " .. table.concat(validation.errors, ", "),
        }
    end

    local manifest = validation.manifest
    local restore_point_path = nil

    -- Create restore point if not disabled
    if not options.skip_restore_point then
        local restore_result = self:createRestorePoint()
        if not restore_result.success then
            logger.warn("BackupManager: Failed to create restore point: " .. (restore_result.error or "unknown error"))
            -- Don't continue without restore point - too risky
            self:_releaseLock()
            return {
                success = false,
                error = "Failed to create restore point. Aborting restore for safety.",
            }
        end
        restore_point_path = restore_result.backup_path
    end

    -- Extract backup to temp directory (with random suffix)
    local random_suffix = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
    local temp_dir = self.BACKUP_DIR .. "/.temp_restore_" .. random_suffix
    local success, err_msg = self:_extractArchive(backup_path, temp_dir)

    if not success then
        self:_releaseLock()
        return {
            success = false,
            error = err_msg,
        }
    end

    local conflicts = {}
    local warnings = {}
    local restore_success = false
    local restore_error = nil

    -- Wrap restore operations in pcall for atomic rollback
    local pcall_success, pcall_err = pcall(function()

    -- Restore settings
    if options.restore_settings ~= false and manifest.contents.settings then
        local backup_settings_file = temp_dir .. "/settings/koassistant_settings.lua"
        if lfs.attributes(backup_settings_file, "mode") == "file" then
            local current_settings_file = self.SETTINGS_DIR .. "/koassistant_settings.lua"

            if options.merge_mode then
                -- Merge mode: intelligently merge settings
                local current_settings = LuaSettings:open(current_settings_file)
                local backup_settings = LuaSettings:open(backup_settings_file)

                -- Merge features
                local current_features = current_settings:readSetting("features") or {}
                local backup_features = backup_settings:readSetting("features") or {}

                -- Merge API keys if requested
                if options.restore_api_keys and manifest.contents.api_keys then
                    if backup_features.api_keys then
                        current_features.api_keys = current_features.api_keys or {}
                        for provider, key in pairs(backup_features.api_keys) do
                            current_features.api_keys[provider] = key
                        end
                    end
                end

                -- Merge other features (backup takes precedence)
                for key, value in pairs(backup_features) do
                    if key ~= "api_keys" or (options.restore_api_keys and manifest.contents.api_keys) then
                        current_features[key] = value
                    end
                end

                -- Validate and clean custom actions from features
                if current_features.custom_actions then
                    local valid_actions, action_warnings = self:_validateCustomActions(current_features.custom_actions)
                    current_features.custom_actions = valid_actions
                    for _idx, warning in ipairs(action_warnings) do
                        table.insert(warnings, warning)
                    end
                end

                -- Save merged features
                current_settings:saveSetting("features", current_features)

                -- Merge other top-level settings with validation
                for key, value in pairs(backup_settings.data) do
                    if key ~= "features" then
                        -- Validate action overrides
                        if key == "builtin_action_overrides" then
                            local valid_overrides, override_warnings = self:_validateActionOverrides(value)
                            current_settings:saveSetting(key, valid_overrides)
                            for _idx, warning in ipairs(override_warnings) do
                                table.insert(warnings, warning)
                            end
                        -- Validate top-level custom actions
                        elseif key == "custom_actions" then
                            local valid_actions, action_warnings = self:_validateCustomActions(value)
                            current_settings:saveSetting(key, valid_actions)
                            for _idx, warning in ipairs(action_warnings) do
                                table.insert(warnings, warning)
                            end
                        else
                            current_settings:saveSetting(key, value)
                        end
                    end
                end

                current_settings:flush()
            else
                -- Replace mode: replace entire settings file with validation
                local backup_settings = LuaSettings:open(backup_settings_file)
                local backup_features = backup_settings:readSetting("features") or {}

                -- Validate custom actions in features
                if backup_features.custom_actions then
                    local valid_actions, action_warnings = self:_validateCustomActions(backup_features.custom_actions)
                    backup_features.custom_actions = valid_actions
                    for _idx, warning in ipairs(action_warnings) do
                        table.insert(warnings, warning)
                    end
                end

                -- Create new settings file with validated data
                local new_settings = LuaSettings:open(current_settings_file)
                new_settings:saveSetting("features", backup_features)

                -- Copy other top-level settings with validation
                for key, value in pairs(backup_settings.data) do
                    if key ~= "features" then
                        -- Validate action overrides
                        if key == "builtin_action_overrides" then
                            local valid_overrides, override_warnings = self:_validateActionOverrides(value)
                            new_settings:saveSetting(key, valid_overrides)
                            for _idx, warning in ipairs(override_warnings) do
                                table.insert(warnings, warning)
                            end
                        -- Validate top-level custom actions
                        elseif key == "custom_actions" then
                            local valid_actions, action_warnings = self:_validateCustomActions(value)
                            new_settings:saveSetting(key, valid_actions)
                            for _idx, warning in ipairs(action_warnings) do
                                table.insert(warnings, warning)
                            end
                        else
                            new_settings:saveSetting(key, value)
                        end
                    end
                end

                new_settings:flush()

                -- If not restoring API keys, restore them from current settings
                if not options.restore_api_keys or not manifest.contents.api_keys then
                    table.insert(warnings, "API keys were not included in backup. You may need to re-enter them.")
                end
            end
        end
    end

    -- Restore config files
    if options.restore_configs ~= false and manifest.contents.config_files then
        -- Restore apikeys.lua if included and requested
        if options.restore_api_keys and manifest.contents.api_keys then
            local backup_apikeys = temp_dir .. "/configs/apikeys.lua"
            if lfs.attributes(backup_apikeys, "mode") == "file" then
                local dest_apikeys = self.PLUGIN_DIR .. "/apikeys.lua"
                self:_copyFile(backup_apikeys, dest_apikeys)
            end
        end

        -- Restore configuration.lua if exists
        local backup_config = temp_dir .. "/configs/configuration.lua"
        if lfs.attributes(backup_config, "mode") == "file" then
            local dest_config = self.PLUGIN_DIR .. "/configuration.lua"
            self:_copyFile(backup_config, dest_config)
        end

        -- Restore custom_actions.lua if exists
        local backup_actions = temp_dir .. "/configs/custom_actions.lua"
        if lfs.attributes(backup_actions, "mode") == "file" then
            local dest_actions = self.PLUGIN_DIR .. "/custom_actions.lua"
            self:_copyFile(backup_actions, dest_actions)
        end
    end

    -- Restore user content
    if options.restore_content ~= false and (manifest.contents.domains or manifest.contents.behaviors) then
        -- Restore domains
        local backup_domains = temp_dir .. "/domains"
        if lfs.attributes(backup_domains, "mode") == "directory" then
            local dest_domains = self.PLUGIN_DIR .. "/domains"
            if not options.merge_mode then
                -- Replace mode: clear existing domains first
                if lfs.attributes(dest_domains, "mode") == "directory" then
                    local safe_path, _ = self:_sanitizePath(dest_domains)
                    if safe_path then
                        os.execute(string.format('rm -rf "%s"', safe_path))
                    end
                end
            end
            self:_copyDirectory(backup_domains, dest_domains)
        end

        -- Restore behaviors
        local backup_behaviors = temp_dir .. "/behaviors"
        if lfs.attributes(backup_behaviors, "mode") == "directory" then
            local dest_behaviors = self.PLUGIN_DIR .. "/behaviors"
            if not options.merge_mode then
                -- Replace mode: clear existing behaviors first
                if lfs.attributes(dest_behaviors, "mode") == "directory" then
                    local safe_path, _ = self:_sanitizePath(dest_behaviors)
                    if safe_path then
                        os.execute(string.format('rm -rf "%s"', safe_path))
                    end
                end
            end
            self:_copyDirectory(backup_behaviors, dest_behaviors)
        end
    end

    -- Restore chat history
    if options.restore_chats and manifest.contents.chats then
        -- Detect backup format: JSON (v2) or directory (v1)
        local json_path = temp_dir .. "/koassistant_chats.json"
        local backup_chats_dir = temp_dir .. "/chats"

        if lfs.attributes(json_path, "mode") == "file" then
            -- v2: JSON backup - restore to DocSettings
            logger.info("BackupManager: Restoring chats from JSON (v2 format)")

            local json_success, json_err = self:restoreChatsFromJSON(json_path, options.merge_mode)
            if not json_success then
                logger.err("BackupManager: Failed to restore chats from JSON:", json_err)
                table.insert(warnings, "Failed to restore some chats: " .. (json_err or "unknown error"))
            end
        elseif lfs.attributes(backup_chats_dir, "mode") == "directory" then
            -- v1: Legacy directory backup - restore to CHAT_DIR
            logger.info("BackupManager: Restoring chats from directory (v1 format)")

            if not options.merge_mode then
                -- Replace mode: clear existing chats first
                if lfs.attributes(self.CHAT_DIR, "mode") == "directory" then
                    local safe_path, _ = self:_sanitizePath(self.CHAT_DIR)
                    if safe_path then
                        os.execute(string.format('rm -rf "%s"', safe_path))
                    end
                end
            end

            self:_copyDirectory(backup_chats_dir, self.CHAT_DIR)
        else
            logger.warn("BackupManager: No chat backup found in archive (neither JSON nor directory)")
        end
    end

        -- Mark restore as successful
        restore_success = true
    end)  -- End of pcall

    -- Clean up temp directory
    self:_removeTempDir(temp_dir)

    -- Handle restore result
    if pcall_success and restore_success then
        -- Restore succeeded
        self:_releaseLock()
        logger.info("BackupManager: Successfully restored backup: " .. backup_path)

        return {
            success = true,
            conflicts = conflicts,
            warnings = warnings,
        }
    else
        -- Restore failed - rollback if we have a restore point
        logger.err("BackupManager: Restore failed:", pcall_err or "unknown error")
        restore_error = pcall_err or "Restore operation failed"

        if restore_point_path and not options.skip_restore_point then
            logger.warn("BackupManager: Attempting rollback to restore point...")

            -- Attempt rollback
            local rollback_options = {
                skip_restore_point = true,  -- Don't create another restore point
                restore_settings = true,
                restore_api_keys = true,
                restore_configs = true,
                restore_content = true,
                restore_chats = false,
                merge_mode = false,  -- Full replace for rollback
            }

            local rollback_result = self:restoreBackup(restore_point_path, rollback_options)

            if rollback_result.success then
                logger.info("BackupManager: Successfully rolled back to restore point")
                self:_releaseLock()
                return {
                    success = false,
                    error = "Restore failed and was rolled back: " .. restore_error,
                    rolled_back = true,
                }
            else
                logger.err("BackupManager: Rollback also failed:", rollback_result.error)
                self:_releaseLock()
                return {
                    success = false,
                    error = "Restore failed AND rollback failed. Manual recovery may be needed. Original error: " .. restore_error,
                    rolled_back = false,
                    rollback_error = rollback_result.error,
                }
            end
        else
            -- No restore point, just return error
            self:_releaseLock()
            return {
                success = false,
                error = restore_error,
            }
        end
    end
end

-- List all backups
function BackupManager:listBackups()
    local backups = {}

    if not lfs.attributes(self.BACKUP_DIR, "mode") then
        return backups
    end

    for entry in lfs.dir(self.BACKUP_DIR) do
        if entry:match("%.koa$") then
            local backup_path = self.BACKUP_DIR .. "/" .. entry
            local attr = lfs.attributes(backup_path)

            if attr and attr.mode == "file" then
                -- Try to read manifest
                local validation = self:validateBackup(backup_path)
                local manifest = validation.valid and validation.manifest or nil

                local is_restore_point = entry:match("^koassistant_restore_point_")

                table.insert(backups, {
                    path = backup_path,
                    name = entry,
                    size = attr.size,
                    modified = attr.modification,
                    manifest = manifest,
                    is_restore_point = is_restore_point or false,
                })
            end
        end
    end

    -- Sort by modification time (newest first)
    table.sort(backups, function(a, b)
        return a.modified > b.modified
    end)

    return backups
end

-- Delete backup
function BackupManager:deleteBackup(backup_path)
    if not lfs.attributes(backup_path, "mode") then
        return { success = false, error = "Backup file does not exist" }
    end

    local success, err = os.remove(backup_path)
    if not success then
        logger.err("BackupManager: Failed to delete backup: " .. backup_path)
        return { success = false, error = "Failed to delete backup: " .. (err or "unknown error") }
    end

    logger.info("BackupManager: Deleted backup: " .. backup_path)

    return { success = true }
end

-- Clean up old restore points (older than RESTORE_POINT_RETENTION_DAYS)
function BackupManager:cleanupOldRestorePoints()
    local backups = self:listBackups()
    local current_time = os.time()
    local retention_seconds = self.RESTORE_POINT_RETENTION_DAYS * 24 * 60 * 60

    local deleted_count = 0

    for _, backup in ipairs(backups) do
        if backup.is_restore_point then
            local age = current_time - backup.modified
            if age > retention_seconds then
                local result = self:deleteBackup(backup.path)
                if result.success then
                    deleted_count = deleted_count + 1
                end
            end
        end
    end

    if deleted_count > 0 then
        logger.info("BackupManager: Cleaned up " .. deleted_count .. " old restore points")
    end

    return { success = true, deleted_count = deleted_count }
end

return BackupManager
