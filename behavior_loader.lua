-- Behavior loader for KOAssistant
-- Loads behavior definitions from external files
--
-- Sources (in priority order):
--   1. behaviors/           - User behaviors (gitignored, can override built-in)
--   2. prompts/behaviors/   - Built-in behaviors (tracked in git)
--
-- Behavior file format:
--   Filename: behavior_id.md or behavior_id.txt (filename becomes the behavior ID)
--   First line: # Behavior Name (optional, becomes display name)
--   Rest of file: Behavior text sent to AI as system prompt
--
-- Example file: behaviors/concise.md
--   # Concise
--   Be brief and to the point. Avoid unnecessary elaboration...
--
-- If no heading is found, the display name is derived from the filename:
--   concise_expert.md -> "Concise Expert"

local lfs = require("libs/libkoreader-lfs")

local BehaviorLoader = {}

-- Get the plugin directory path
local function getPluginPath()
    local info = debug.getinfo(1, "S")
    local path = info.source:match("@(.*/)")
    return path or "./"
end

-- Read file contents
local function readFile(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

-- Convert filename to display name (snake_case to Title Case)
-- e.g., "concise_expert" -> "Concise Expert"
local function filenameToDisplayName(filename)
    return filename:gsub("_", " "):gsub("(%a)([%w]*)", function(first, rest)
        return first:upper() .. rest
    end)
end

-- Strip HTML/XML comments from content (used for metadata)
-- We keep the content after stripping so the AI doesn't see our metadata comments
local function stripMetadataComments(text)
    -- Remove HTML-style comments <!-- ... -->
    -- Using non-greedy match to handle multiple comments
    return text:gsub("<!%-%-.-%-%->\n?", "")
end

-- Parse a behavior file
-- Returns: { name = "Display Name", text = "..." } or nil
local function parseBehaviorFile(content, fallback_name, source)
    if not content or content == "" then
        return nil
    end

    local name, text

    -- Check for markdown heading on first line
    local first_line, rest = content:match("^([^\n]*)\n(.*)$")
    if not first_line then
        -- Single line file
        first_line = content
        rest = ""
    end

    local heading = first_line:match("^#%s*(.+)%s*$")
    if heading then
        name = heading
        text = rest
    else
        -- No heading found, use filename as name
        name = fallback_name
        text = content
    end

    -- Strip metadata comments from text
    text = stripMetadataComments(text)

    -- Trim whitespace from text
    text = text:match("^%s*(.-)%s*$") or ""

    if text == "" then
        return nil
    end

    return {
        name = name,
        text = text,
        external = true,  -- Mark as loaded from external file
        source = source or "folder",
    }
end

-- Load behaviors from a specific folder path
-- @param folder_path: Full path to the folder
-- @param source: Source identifier ("builtin" or "folder")
-- @return table: behavior_id -> { name, text, external, source }
local function loadFromFolder(folder_path, source)
    local behaviors = {}

    -- Check if folder exists
    local attr = lfs.attributes(folder_path)
    if not attr or attr.mode ~= "directory" then
        return behaviors
    end

    -- Iterate through files in the folder
    for file in lfs.dir(folder_path) do
        -- Only process .md and .txt files, skip README files
        local lower_file = file:lower()
        if (file:match("%.md$") or file:match("%.txt$")) and not lower_file:match("^readme%.") then
            local id = file:gsub("%.md$", ""):gsub("%.txt$", "")
            local content = readFile(folder_path .. file)

            if content then
                local fallback_name = filenameToDisplayName(id)
                local behavior = parseBehaviorFile(content, fallback_name, source)

                if behavior then
                    behaviors[id] = behavior
                end
            end
        end
    end

    return behaviors
end

-- Load all behaviors from user folder only (for backward compatibility)
-- Returns: table of behavior_id -> { name, text, external, source }
function BehaviorLoader.load()
    local behaviors_path = getPluginPath() .. "behaviors/"
    return loadFromFolder(behaviors_path, "folder")
end

-- Load built-in behaviors from prompts/behaviors/
-- Returns: table of behavior_id -> { name, text, external, source }
function BehaviorLoader.loadBuiltin()
    local builtin_path = getPluginPath() .. "prompts/behaviors/"
    return loadFromFolder(builtin_path, "builtin")
end

-- Load all behaviors from all sources
-- User behaviors override built-in behaviors with same ID
-- Returns: table of behavior_id -> { name, text, external, source }
function BehaviorLoader.loadAll()
    local all_behaviors = {}

    -- Load built-in first (lower priority)
    local builtin = BehaviorLoader.loadBuiltin()
    for id, behavior in pairs(builtin) do
        all_behaviors[id] = behavior
    end

    -- Load user behaviors (higher priority, overrides built-in)
    local user = BehaviorLoader.load()
    for id, behavior in pairs(user) do
        all_behaviors[id] = behavior
    end

    return all_behaviors
end

-- Get sorted list of behavior IDs for UI
-- Sorts alphabetically by display name
function BehaviorLoader.getSortedIds(behaviors)
    local ids = {}
    for id in pairs(behaviors) do
        table.insert(ids, id)
    end
    table.sort(ids, function(a, b)
        return (behaviors[a].name or a) < (behaviors[b].name or b)
    end)
    return ids
end

-- Get a single behavior by ID
function BehaviorLoader.get(behaviors, id)
    return behaviors[id]
end

-- Check if any behaviors are available
function BehaviorLoader.hasAny(behaviors)
    return next(behaviors) ~= nil
end

-- Get the user behaviors folder path (for UI display)
function BehaviorLoader.getFolderPath()
    return getPluginPath() .. "behaviors/"
end

-- Get the built-in behaviors folder path
function BehaviorLoader.getBuiltinPath()
    return getPluginPath() .. "prompts/behaviors/"
end

return BehaviorLoader
