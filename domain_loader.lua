-- Domain loader for KOAssistant
-- Loads domain definitions from external files
--
-- Sources (in priority order):
--   1. domains/           - User domains (gitignored, can override built-in)
--   2. prompts/domains/   - Built-in domains (tracked in git)
--
-- Domain file format:
--   Filename: domain_id.md or domain_id.txt (filename becomes the domain ID)
--   First line: # Domain Name (optional, becomes display name)
--   Rest of file: Context text sent to AI
--
-- Example file: domains/research.md
--   # Research
--   Focus on critical thinking and evidence-based reasoning...
--
-- If no heading is found, the display name is derived from the filename:
--   islamic_studies.md -> "Islamic Studies"

local lfs = require("libs/libkoreader-lfs")

local DomainLoader = {}

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
-- e.g., "islamic_studies" -> "Islamic Studies"
local function filenameToDisplayName(filename)
    return filename:gsub("_", " "):gsub("(%a)([%w]*)", function(first, rest)
        return first:upper() .. rest
    end)
end

-- Strip HTML/XML comments from content (used for metadata)
local function stripMetadataComments(text)
    return text:gsub("<!%-%-.-%-%->\n?", "")
end

-- Parse a domain file
-- Returns: { name = "Display Name", context = "..." } or nil
local function parseDomainFile(content, fallback_name, source)
    if not content or content == "" then
        return nil
    end

    local name, context

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
        context = rest
    else
        -- No heading found, use filename as name
        name = fallback_name
        context = content
    end

    -- Strip metadata comments from context
    context = stripMetadataComments(context)

    -- Trim whitespace from context
    context = context:match("^%s*(.-)%s*$") or ""

    if context == "" then
        return nil
    end

    return {
        name = name,
        context = context,
        external = true,  -- Mark as loaded from external file
        source = source or "folder",
    }
end

-- Load domains from a specific folder path
-- @param folder_path: Full path to the folder
-- @param source: Source identifier ("builtin" or "folder")
-- @return table: domain_id -> { name, context, external, source }
local function loadFromFolder(folder_path, source)
    local domains = {}

    -- Check if folder exists
    local attr = lfs.attributes(folder_path)
    if not attr or attr.mode ~= "directory" then
        return domains
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
                local domain = parseDomainFile(content, fallback_name, source)

                if domain then
                    domains[id] = domain
                end
            end
        end
    end

    return domains
end

-- Load all domains from user folder only (for backward compatibility)
-- Returns: table of domain_id -> { name, context, external, source }
function DomainLoader.load()
    local domains_path = getPluginPath() .. "domains/"
    return loadFromFolder(domains_path, "folder")
end

-- Load built-in domains from prompts/domains/
-- Returns: table of domain_id -> { name, context, external, source }
function DomainLoader.loadBuiltin()
    local builtin_path = getPluginPath() .. "prompts/domains/"
    return loadFromFolder(builtin_path, "builtin")
end

-- Load all domains from all sources
-- User domains override built-in domains with same ID
-- Returns: table of domain_id -> { name, context, external, source }
function DomainLoader.loadAll()
    local all_domains = {}

    -- Load built-in first (lower priority)
    local builtin = DomainLoader.loadBuiltin()
    for id, domain in pairs(builtin) do
        all_domains[id] = domain
    end

    -- Load user domains (higher priority, overrides built-in)
    local user = DomainLoader.load()
    for id, domain in pairs(user) do
        all_domains[id] = domain
    end

    return all_domains
end

-- Get sorted list of domain IDs for UI
-- Sorts alphabetically by display name
function DomainLoader.getSortedIds(domains)
    local ids = {}
    for id in pairs(domains) do
        table.insert(ids, id)
    end
    table.sort(ids, function(a, b)
        return (domains[a].name or a) < (domains[b].name or b)
    end)
    return ids
end

-- Get a single domain by ID
function DomainLoader.get(domains, id)
    return domains[id]
end

-- Check if any domains are available
function DomainLoader.hasAny(domains)
    return next(domains) ~= nil
end

-- Get the user domains folder path (for UI display)
function DomainLoader.getFolderPath()
    return getPluginPath() .. "domains/"
end

-- Get the built-in domains folder path
function DomainLoader.getBuiltinPath()
    return getPluginPath() .. "prompts/domains/"
end

-- Get all domains from all sources: builtin, folder, and UI-created
-- @param custom_domains: Array of UI-created domains from settings (optional)
-- @return table: { id = { id, name, context, source, display_name } }
function DomainLoader.getAllDomains(custom_domains)
    local all_domains = {}

    -- Load all file-based domains (builtin + user folder)
    local file_domains = DomainLoader.loadAll()

    for id, domain in pairs(file_domains) do
        local display_suffix = domain.source == "builtin" and "" or " (file)"
        all_domains[id] = {
            id = id,
            name = domain.name,
            context = domain.context,
            source = domain.source,
            display_name = domain.name .. display_suffix,
            external = domain.source ~= "builtin",
        }
    end

    -- Add UI-created domains
    if custom_domains and type(custom_domains) == "table" then
        for _, domain in ipairs(custom_domains) do
            if domain.id and domain.context then
                all_domains[domain.id] = {
                    id = domain.id,
                    name = domain.name or domain.id,
                    context = domain.context,
                    source = "ui",
                    display_name = (domain.name or domain.id) .. " (custom)",
                }
            end
        end
    end

    return all_domains
end

-- Get sorted list of domain entries for UI display
-- @param custom_domains: Array of UI-created domains from settings (optional)
-- @return table: Array of domain entries sorted by display_name
function DomainLoader.getSortedDomains(custom_domains)
    local all = DomainLoader.getAllDomains(custom_domains)
    local sorted = {}

    for _, domain in pairs(all) do
        table.insert(sorted, domain)
    end

    table.sort(sorted, function(a, b)
        -- Built-ins first, then folders, then UI
        local order = { builtin = 1, folder = 2, ui = 3 }
        if order[a.source] ~= order[b.source] then
            return order[a.source] < order[b.source]
        end
        return (a.display_name or a.name) < (b.display_name or b.name)
    end)

    return sorted
end

-- Get a specific domain by ID
-- @param id: Domain ID to look up
-- @param custom_domains: Array of UI-created domains from settings (optional)
-- @return table or nil: Domain entry or nil if not found
function DomainLoader.getDomainById(id, custom_domains)
    if not id then return nil end

    -- Check all file-based domains (builtin + user folder)
    local file_domains = DomainLoader.loadAll()
    if file_domains[id] then
        local domain = file_domains[id]
        local display_suffix = domain.source == "builtin" and "" or " (file)"
        return {
            id = id,
            name = domain.name,
            context = domain.context,
            source = domain.source,
            display_name = domain.name .. display_suffix,
            external = domain.source ~= "builtin",
        }
    end

    -- Check UI-created domains
    if custom_domains and type(custom_domains) == "table" then
        for _, domain in ipairs(custom_domains) do
            if domain.id == id then
                return {
                    id = domain.id,
                    name = domain.name or domain.id,
                    context = domain.context,
                    source = "ui",
                    display_name = (domain.name or domain.id) .. " (custom)",
                }
            end
        end
    end

    return nil
end

return DomainLoader
