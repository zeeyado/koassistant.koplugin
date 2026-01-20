-- Domain loader for KOAssistant
-- Loads domain definitions from external files in the domains/ folder
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

-- Parse a domain file
-- Returns: { name = "Display Name", context = "..." } or nil
local function parseDomainFile(content, fallback_name)
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

    -- Trim whitespace from context
    context = context:match("^%s*(.-)%s*$") or ""

    if context == "" then
        return nil
    end

    return {
        name = name,
        context = context,
        external = true,  -- Mark as loaded from external file
        source = "folder",
    }
end

-- Load all domains from the domains/ folder
-- Returns: table of domain_id -> { name, context, external }
function DomainLoader.load()
    local domains = {}
    local domains_path = getPluginPath() .. "domains/"

    -- Check if domains folder exists
    local attr = lfs.attributes(domains_path)
    if not attr or attr.mode ~= "directory" then
        -- No domains folder, return empty
        return domains
    end

    -- Iterate through files in the domains folder
    for file in lfs.dir(domains_path) do
        -- Only process .md and .txt files
        if file:match("%.md$") or file:match("%.txt$") then
            local id = file:gsub("%.md$", ""):gsub("%.txt$", "")
            local content = readFile(domains_path .. file)

            if content then
                local fallback_name = filenameToDisplayName(id)
                local domain = parseDomainFile(content, fallback_name)

                if domain then
                    domains[id] = domain
                end
            end
        end
    end

    return domains
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

-- Get the domains folder path (for UI display)
function DomainLoader.getFolderPath()
    return getPluginPath() .. "domains/"
end

-- Get all domains from all sources: folder and UI-created
-- @param custom_domains: Array of UI-created domains from settings (optional)
-- @return table: { id = { id, name, context, source, display_name } }
function DomainLoader.getAllDomains(custom_domains)
    local all_domains = {}

    -- Load folder domains
    local folder_domains = DomainLoader.load()
    local folder_names = {}

    for id, domain in pairs(folder_domains) do
        folder_names[domain.name:lower()] = true
        all_domains[id] = {
            id = id,
            name = domain.name,
            context = domain.context,
            source = "folder",
            display_name = domain.name,
            external = true,
        }
    end

    -- Add UI-created domains
    if custom_domains and type(custom_domains) == "table" then
        for _, domain in ipairs(custom_domains) do
            if domain.id and domain.context then
                -- Handle name conflicts with folder domains
                local display_name = domain.name or domain.id
                if folder_names[display_name:lower()] then
                    display_name = display_name .. " (custom)"
                else
                    display_name = display_name .. " (custom)"
                end

                all_domains[domain.id] = {
                    id = domain.id,
                    name = domain.name or domain.id,
                    context = domain.context,
                    source = "ui",
                    display_name = display_name,
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
        -- Folder first, then UI
        local order = { folder = 1, ui = 2 }
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

    -- Check folder domains first
    local folder_domains = DomainLoader.load()
    if folder_domains[id] then
        local domain = folder_domains[id]
        return {
            id = id,
            name = domain.name,
            context = domain.context,
            source = "folder",
            display_name = domain.name,
            external = true,
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
