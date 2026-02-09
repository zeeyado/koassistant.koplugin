--- X-Ray JSON parser and renderer
--- Pure data module: no UI dependencies.
--- Handles JSON parsing, markdown rendering, character search, and chapter matching.

local json = require("json")
local logger = require("logger")
local _ = require("koassistant_gettext")

local XrayParser = {}

--- Detect whether a cache result string is JSON or legacy markdown
--- Checks for raw JSON, code-fenced JSON, and JSON preceded by text
--- @param result string The cached result text
--- @return boolean is_json True if result appears to be JSON
function XrayParser.isJSON(result)
    if type(result) ~= "string" then return false end
    -- Raw JSON starting with {
    if result:match("^%s*{") then return true end
    -- Code-fenced JSON (```json ... ``` or ``` { ... ```)
    if result:match("```json%s*{") or result:match("```%s*{") then return true end
    -- JSON embedded after some preamble text (look for { within first 200 chars)
    local first_brace = result:find("{")
    if first_brace and first_brace <= 200 then return true end
    return false
end

-- Known category keys for validating parsed X-Ray data
local FICTION_KEYS = { "characters", "locations", "themes", "lexicon", "timeline", "current_state" }
local NONFICTION_KEYS = { "key_figures", "core_concepts", "arguments", "terminology", "argument_development", "current_position" }

--- Check if a table looks like valid X-Ray data (has at least one recognized category key)
--- Also infers and sets the type field if missing.
--- @param data table Candidate parsed data
--- @return boolean valid True if data has recognized X-Ray structure
local function isValidXrayData(data)
    if type(data) ~= "table" then return false end
    -- Check for error response
    if data.error then return true end
    -- Check for fiction keys
    for _idx, key in ipairs(FICTION_KEYS) do
        if data[key] then
            if not data.type then data.type = "fiction" end
            return true
        end
    end
    -- Check for non-fiction keys
    for _idx, key in ipairs(NONFICTION_KEYS) do
        if data[key] then
            if not data.type then data.type = "nonfiction" end
            return true
        end
    end
    return false
end

--- Attempt to extract valid JSON from a potentially wrapped response
--- Tries: raw decode, code fence stripping, first-brace-to-last-brace extraction
--- Accepts any table with recognized X-Ray category keys (type field inferred if missing).
--- @param text string The raw AI response
--- @return table|nil data Parsed Lua table, or nil on failure
--- @return string|nil err Error message if all attempts failed
function XrayParser.parse(text)
    if type(text) ~= "string" or text == "" then
        return nil, "empty input"
    end

    -- Attempt 1: direct decode
    local ok, data = pcall(json.decode, text)
    if ok and isValidXrayData(data) then
        return data, nil
    end

    -- Attempt 2: strip markdown code fences
    local stripped = text:match("```json%s*(.-)%s*```")
        or text:match("```%s*({.+})%s*```")
    if stripped then
        ok, data = pcall(json.decode, stripped)
        if ok and isValidXrayData(data) then
            return data, nil
        end
    end

    -- Attempt 3: extract from first { to last }
    local first_brace = text:find("{")
    local last_brace = text:match(".*()}")
    if first_brace and last_brace and last_brace > first_brace then
        local extracted = text:sub(first_brace, last_brace)
        ok, data = pcall(json.decode, extracted)
        if ok and isValidXrayData(data) then
            return data, nil
        end
    end

    return nil, "failed to parse JSON from response"
end

--- Check if X-Ray data is fiction type
--- Falls back to key-based detection if type field is missing
--- @param data table Parsed X-Ray data
--- @return boolean
function XrayParser.isFiction(data)
    if data.type then return data.type == "fiction" end
    -- Infer from keys: fiction has "characters", nonfiction has "key_figures"
    return data.characters ~= nil
end

--- Get the key used for characters/figures in this X-Ray type
--- @param data table Parsed X-Ray data
--- @return string key "characters" for fiction, "key_figures" for non-fiction
function XrayParser.getCharacterKey(data)
    return XrayParser.isFiction(data) and "characters" or "key_figures"
end

--- Get characters/figures array from X-Ray data
--- @param data table Parsed X-Ray data
--- @return table characters Array of character/figure entries
function XrayParser.getCharacters(data)
    local key = XrayParser.getCharacterKey(data)
    return data[key] or {}
end

--- Get category definitions for building menus
--- @param data table Parsed X-Ray data
--- @return table categories Array of {key, label, items, singular_label}
function XrayParser.getCategories(data)
    if XrayParser.isFiction(data) then
        return {
            { key = "characters",    label = _("Cast"),          items = data.characters or {} },
            { key = "locations",     label = _("World"),         items = data.locations or {} },
            { key = "themes",        label = _("Ideas"),         items = data.themes or {} },
            { key = "lexicon",       label = _("Lexicon"),       items = data.lexicon or {} },
            { key = "timeline",      label = _("Story Arc"),     items = data.timeline or {} },
            { key = "current_state", label = _("Current State"), items = data.current_state and { data.current_state } or {} },
        }
    else
        return {
            { key = "key_figures",          label = _("Key Figures"),          items = data.key_figures or {} },
            { key = "core_concepts",        label = _("Core Concepts"),        items = data.core_concepts or {} },
            { key = "arguments",            label = _("Arguments"),            items = data.arguments or {} },
            { key = "terminology",          label = _("Terminology"),          items = data.terminology or {} },
            { key = "argument_development", label = _("Argument Development"), items = data.argument_development or {} },
            { key = "current_position",     label = _("Current Position"),     items = data.current_position and { data.current_position } or {} },
        }
    end
end

--- Get the display name for an item depending on category
--- @param item table The item entry
--- @param category_key string The category key
--- @return string name The display name
function XrayParser.getItemName(item, category_key)
    if category_key == "lexicon" or category_key == "terminology" then
        return item.term or _("Unknown")
    end
    if category_key == "timeline" or category_key == "argument_development" then
        return item.event or _("Unknown")
    end
    return item.name or _("Unknown")
end

--- Get the secondary text for an item (used as subtitle or mandatory text)
--- @param item table The item entry
--- @param category_key string The category key
--- @return string secondary The secondary display text
function XrayParser.getItemSecondary(item, category_key)
    if category_key == "characters" or category_key == "key_figures" then
        return item.role or ""
    end
    if category_key == "timeline" or category_key == "argument_development" then
        return item.chapter or ""
    end
    if category_key == "lexicon" or category_key == "terminology" then
        return ""
    end
    return ""
end

--- Format a single item's detail text for display
--- @param item table The item entry
--- @param category_key string The category key
--- @return string detail Formatted detail text
function XrayParser.formatItemDetail(item, category_key)
    local parts = {}

    if category_key == "characters" or category_key == "key_figures" then
        local name = item.name or _("Unknown")
        local role = item.role or ""
        if role ~= "" then
            table.insert(parts, name .. " (" .. role .. ")")
        else
            table.insert(parts, name)
        end
        table.insert(parts, "")

        if item.aliases and #item.aliases > 0 then
            table.insert(parts, _("Also known as:") .. " " .. table.concat(item.aliases, ", "))
            table.insert(parts, "")
        end

        if item.description and item.description ~= "" then
            table.insert(parts, item.description)
            table.insert(parts, "")
        end

        if item.connections and #item.connections > 0 then
            table.insert(parts, _("Connections:") .. " " .. table.concat(item.connections, ", "))
        end

    elseif category_key == "locations" or category_key == "core_concepts" then
        table.insert(parts, item.name or _("Unknown"))
        table.insert(parts, "")
        if item.description and item.description ~= "" then
            table.insert(parts, item.description)
            table.insert(parts, "")
        end
        local sig = item.significance or item.importance
        if sig and sig ~= "" then
            table.insert(parts, _("Significance:") .. " " .. sig)
        end

    elseif category_key == "themes" or category_key == "arguments" then
        table.insert(parts, item.name or _("Unknown"))
        table.insert(parts, "")
        if item.description and item.description ~= "" then
            table.insert(parts, item.description)
            table.insert(parts, "")
        end
        if item.evidence and item.evidence ~= "" then
            table.insert(parts, _("Evidence:") .. " " .. item.evidence)
        end

    elseif category_key == "lexicon" or category_key == "terminology" then
        table.insert(parts, item.term or _("Unknown"))
        table.insert(parts, "")
        if item.definition and item.definition ~= "" then
            table.insert(parts, item.definition)
        end

    elseif category_key == "timeline" or category_key == "argument_development" then
        local event = item.event or _("Unknown")
        local chapter = item.chapter or ""
        if chapter ~= "" then
            table.insert(parts, chapter .. ": " .. event)
        else
            table.insert(parts, event)
        end
        table.insert(parts, "")
        if item.significance and item.significance ~= "" then
            table.insert(parts, item.significance)
            table.insert(parts, "")
        end
        if item.characters and #item.characters > 0 then
            table.insert(parts, _("Characters:") .. " " .. table.concat(item.characters, ", "))
        end

    elseif category_key == "current_state" or category_key == "current_position" then
        if item.summary and item.summary ~= "" then
            table.insert(parts, item.summary)
            table.insert(parts, "")
        end
        local conflicts = item.conflicts
        if conflicts and #conflicts > 0 then
            table.insert(parts, _("Active conflicts:"))
            for _idx, c in ipairs(conflicts) do
                table.insert(parts, "- " .. c)
            end
            table.insert(parts, "")
        end
        local questions = item.questions or item.questions_addressed
        if questions and #questions > 0 then
            local label = category_key == "current_position"
                and _("Questions addressed:") or _("Unanswered questions:")
            table.insert(parts, label)
            for _idx, q in ipairs(questions) do
                table.insert(parts, "- " .. q)
            end
            table.insert(parts, "")
        end
        if item.building_toward and #item.building_toward > 0 then
            table.insert(parts, _("Building toward:"))
            for _idx, b in ipairs(item.building_toward) do
                table.insert(parts, "- " .. b)
            end
        end
    end

    return table.concat(parts, "\n")
end

--- Render structured X-Ray data to readable markdown
--- Produces output matching the established X-Ray style for display in chat and {xray_cache_section}
--- @param data table Parsed X-Ray JSON
--- @param title string Book title (optional, for header)
--- @param progress string Reading progress e.g. "42%" (optional, for header)
--- @return string markdown Rendered markdown text
function XrayParser.renderToMarkdown(data, title, progress)
    local lines = {}

    -- Header
    local header = "# Reader's Companion"
    if title and title ~= "" then
        header = header .. ": " .. title
    end
    if progress and progress ~= "" then
        header = header .. " (Through " .. progress .. ")"
    end
    table.insert(lines, header)
    table.insert(lines, "")

    local type_label = XrayParser.isFiction(data) and "FICTION" or "NON-FICTION"
    table.insert(lines, "**Type: " .. type_label .. "**")
    table.insert(lines, "")

    local categories = XrayParser.getCategories(data)
    for _idx, cat in ipairs(categories) do
        if cat.items and #cat.items > 0 then
            table.insert(lines, "## " .. cat.label)

            if cat.key == "current_state" or cat.key == "current_position" then
                -- Current state: render inline
                local state = cat.items[1]
                if state.summary and state.summary ~= "" then
                    table.insert(lines, state.summary)
                    table.insert(lines, "")
                end
                if state.conflicts and #state.conflicts > 0 then
                    for _idx2, c in ipairs(state.conflicts) do
                        table.insert(lines, "- " .. c)
                    end
                    table.insert(lines, "")
                end
                local questions = state.questions or state.questions_addressed
                if questions and #questions > 0 then
                    for _idx2, q in ipairs(questions) do
                        table.insert(lines, "- " .. q)
                    end
                    table.insert(lines, "")
                end
                if state.building_toward and #state.building_toward > 0 then
                    for _idx2, b in ipairs(state.building_toward) do
                        table.insert(lines, "- " .. b)
                    end
                    table.insert(lines, "")
                end
            elseif cat.key == "characters" or cat.key == "key_figures" then
                for _idx2, char in ipairs(cat.items) do
                    local entry = "**" .. (char.name or "Unknown") .. "**"
                    local desc_parts = {}
                    if char.role and char.role ~= "" then
                        table.insert(desc_parts, char.role)
                    end
                    if char.description and char.description ~= "" then
                        table.insert(desc_parts, char.description)
                    end
                    if #desc_parts > 0 then
                        entry = entry .. " — " .. table.concat(desc_parts, ". ")
                    end
                    table.insert(lines, entry)

                    if char.aliases and #char.aliases > 0 then
                        table.insert(lines, "*(Also known as: " .. table.concat(char.aliases, ", ") .. ")*")
                    end
                    if char.connections and #char.connections > 0 then
                        table.insert(lines, "*Connections: " .. table.concat(char.connections, ", ") .. "*")
                    end
                    table.insert(lines, "")
                end
            elseif cat.key == "locations" or cat.key == "core_concepts" then
                for _idx2, loc in ipairs(cat.items) do
                    local entry = "**" .. (loc.name or "Unknown") .. "**"
                    local desc = loc.description or ""
                    local sig = loc.significance or loc.importance or ""
                    local detail_parts = {}
                    if desc ~= "" then table.insert(detail_parts, desc) end
                    if sig ~= "" then table.insert(detail_parts, sig) end
                    if #detail_parts > 0 then
                        entry = entry .. " — " .. table.concat(detail_parts, ". ")
                    end
                    table.insert(lines, entry)
                    table.insert(lines, "")
                end
            elseif cat.key == "themes" or cat.key == "arguments" then
                for _idx2, theme in ipairs(cat.items) do
                    local entry = "**" .. (theme.name or "Unknown") .. "**"
                    if theme.description and theme.description ~= "" then
                        entry = entry .. " — " .. theme.description
                    end
                    if theme.evidence and theme.evidence ~= "" then
                        entry = entry .. " " .. theme.evidence
                    end
                    table.insert(lines, entry)
                    table.insert(lines, "")
                end
            elseif cat.key == "lexicon" or cat.key == "terminology" then
                for _idx2, term in ipairs(cat.items) do
                    local entry = "**" .. (term.term or "Unknown") .. "**"
                    if term.definition and term.definition ~= "" then
                        entry = entry .. " — " .. term.definition
                    end
                    table.insert(lines, entry)
                    table.insert(lines, "")
                end
            elseif cat.key == "timeline" or cat.key == "argument_development" then
                for _idx2, event in ipairs(cat.items) do
                    local prefix = ""
                    if event.chapter and event.chapter ~= "" then
                        prefix = "**" .. event.chapter .. ":** "
                    else
                        prefix = "- "
                    end
                    local entry = prefix .. (event.event or "Unknown")
                    if event.significance and event.significance ~= "" then
                        entry = entry .. " — " .. event.significance
                    end
                    if event.characters and #event.characters > 0 then
                        entry = entry .. " [" .. table.concat(event.characters, ", ") .. "]"
                    end
                    table.insert(lines, "- " .. entry)
                end
                table.insert(lines, "")
            end
        end
    end

    return table.concat(lines, "\n")
end

--- Search characters/figures by query string
--- Matches against name, aliases, and description (case-insensitive)
--- @param data table Parsed X-Ray data
--- @param query string Search term
--- @return table results Array of {item, match_field} sorted by match quality
function XrayParser.searchCharacters(data, query)
    if not query or query == "" then return {} end

    local characters = XrayParser.getCharacters(data)
    if not characters or #characters == 0 then return {} end

    local query_lower = query:lower()
    local results = {}

    for _idx, char in ipairs(characters) do
        local match_field = nil

        -- Check name (highest priority)
        if char.name and char.name:lower():find(query_lower, 1, true) then
            match_field = "name"
        end

        -- Check aliases
        if not match_field and char.aliases then
            for _idx2, alias in ipairs(char.aliases) do
                if alias:lower():find(query_lower, 1, true) then
                    match_field = "alias"
                    break
                end
            end
        end

        -- Check description (lowest priority)
        if not match_field and char.description then
            if char.description:lower():find(query_lower, 1, true) then
                match_field = "description"
            end
        end

        if match_field then
            table.insert(results, { item = char, match_field = match_field })
        end
    end

    -- Sort: name matches first, then alias, then description
    local priority = { name = 1, alias = 2, description = 3 }
    table.sort(results, function(a, b)
        return (priority[a.match_field] or 9) < (priority[b.match_field] or 9)
    end)

    return results
end

--- Search across all categories (name, term, event, description, etc.)
--- @param data table Parsed X-Ray data
--- @param query string Search query
--- @return table results Array of {item, category_key, category_label, match_field}
function XrayParser.searchAll(data, query)
    if not query or query == "" then return {} end

    local categories = XrayParser.getCategories(data)
    local query_lower = query:lower()
    local results = {}

    for _idx, cat in ipairs(categories) do
        -- Skip current_state/current_position (not useful in search)
        if cat.key ~= "current_state" and cat.key ~= "current_position" then
            for _idx2, item in ipairs(cat.items) do
                local match_field = nil
                -- Check primary name/term/event
                local name = item.name or item.term or item.event or ""
                if name ~= "" and name:lower():find(query_lower, 1, true) then
                    match_field = "name"
                end
                -- Check aliases
                if not match_field and item.aliases then
                    for _idx3, alias in ipairs(item.aliases) do
                        if alias:lower():find(query_lower, 1, true) then
                            match_field = "alias"
                            break
                        end
                    end
                end
                -- Check description/definition/significance
                if not match_field then
                    local desc = item.description or item.definition or item.significance or ""
                    if desc ~= "" and desc:lower():find(query_lower, 1, true) then
                        match_field = "description"
                    end
                end
                if match_field then
                    table.insert(results, {
                        item = item,
                        category_key = cat.key,
                        category_label = cat.label,
                        match_field = match_field,
                    })
                end
            end
        end
    end

    -- Sort: name matches first, then alias, then description
    local priority = { name = 1, alias = 2, description = 3 }
    table.sort(results, function(a, b)
        return (priority[a.match_field] or 9) < (priority[b.match_field] or 9)
    end)

    return results
end

--- Find characters appearing in chapter text using fuzzy name+alias matching
--- @param data table Parsed X-Ray data
--- @param chapter_text string The chapter text content
--- @return table results Array of {item, count} sorted by mention frequency (descending)
function XrayParser.findCharactersInChapter(data, chapter_text)
    if not chapter_text or chapter_text == "" then return {} end

    local characters = XrayParser.getCharacters(data)
    if not characters or #characters == 0 then return {} end

    local text_lower = chapter_text:lower()
    local results = {}

    for _idx, char in ipairs(characters) do
        local best_count = 0

        -- Count mentions of full name
        if char.name and #char.name > 2 then
            local count = XrayParser._countOccurrences(text_lower, char.name:lower())
            if count > best_count then best_count = count end
        end

        -- Count mentions of each alias (AI provides explicit aliases like "Lizzy", "Miss Bennet")
        if char.aliases then
            for _idx2, alias in ipairs(char.aliases) do
                if #alias > 2 then
                    local count = XrayParser._countOccurrences(text_lower, alias:lower())
                    if count > best_count then best_count = count end
                end
            end
        end

        if best_count > 0 then
            table.insert(results, { item = char, count = best_count })
        end
    end

    -- Sort by mention count descending
    table.sort(results, function(a, b)
        return a.count > b.count
    end)

    return results
end

--- Count word-boundary occurrences of a substring in text (plain search)
--- Only counts matches where the needle is surrounded by non-alphanumeric characters
--- (or string start/end), preventing "Ali" from matching inside "quality".
--- @param text string Haystack (already lowered)
--- @param needle string Needle (already lowered)
--- @return number count
function XrayParser._countOccurrences(text, needle)
    local count = 0
    local pos = 1
    local needle_len = #needle
    local text_len = #text
    while true do
        local start = text:find(needle, pos, true)
        if not start then break end
        -- Check word boundaries: character before/after must be non-alphanumeric
        local before_ok = (start == 1) or not text:sub(start - 1, start - 1):match("[%w']")
        local after_pos = start + needle_len
        local after_ok = (after_pos > text_len) or not text:sub(after_pos, after_pos):match("[%w']")
        if before_ok and after_ok then
            count = count + 1
        end
        pos = start + needle_len
    end
    return count
end

return XrayParser
