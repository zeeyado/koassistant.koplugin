--- X-Ray JSON parser and renderer
--- Pure data module: no UI dependencies.
--- Handles JSON parsing, markdown rendering, character search, and chapter matching.

local json = require("json")
local logger = require("logger")
local _ = require("koassistant_gettext")

local XrayParser = {}

-- AI responses sometimes return strings for array fields. Normalize to table.
local function ensure_array(val)
    if type(val) == "table" then return val end
    if type(val) == "string" and val ~= "" then return { val } end
    return nil
end

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
local FICTION_KEYS = { "characters", "locations", "themes", "lexicon", "timeline", "reader_engagement", "current_state", "conclusion" }
local NONFICTION_KEYS = { "key_figures", "locations", "core_concepts", "arguments", "terminology", "argument_development", "reader_engagement", "current_position", "conclusion" }

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

    -- Attempt 2: strip markdown code fences (find-based to cross newlines)
    local fence_open = text:find("```json%s*\n") or text:find("```%s*\n")
    if fence_open then
        local content_start = text:find("\n", fence_open) + 1
        local fence_close = text:find("\n%s*```%s*$")
        local stripped = fence_close
            and text:sub(content_start, fence_close - 1)
            or text:sub(content_start)
        ok, data = pcall(json.decode, stripped)
        if ok and isValidXrayData(data) then
            return data, nil
        end
    end

    -- Attempt 3: extract from first { to last }
    local first_brace = text:find("{")
    -- Scan backwards (Lua's .* doesn't cross newlines)
    local last_brace
    for i = #text, 1, -1 do
        if text:byte(i) == 125 then -- }
            last_brace = i
            break
        end
    end
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

--- Get the searchable name for an item (name, term, or event depending on type)
--- @param item table An X-Ray item entry
--- @return string|nil name The name to search for, or nil
local function getItemSearchName(item)
    return item.name or item.term or item.event
end

--- Count occurrences of a single item (name + aliases) in pre-lowered text.
--- Finds all match spans from name and aliases, merges overlapping spans,
--- and returns the total unique matches (union semantics, same as regex OR).
--- @param item table An X-Ray item entry (must have name/term/event and optionally aliases)
--- @param text_lower string Already-lowered text to search
--- @return number count Unique match count across name and all aliases (0 if not found or name ≤2 chars)
function XrayParser.countItemOccurrences(item, text_lower)
    local name = getItemSearchName(item)
    if not name or #name <= 2 then return 0 end

    local name_lower = name:lower()

    -- Collect all search terms
    local terms = {}

    -- Handle parenthetical names: "Theosis (Deification)" → "theosis" + "deification"
    local clean_name = name_lower:gsub("%s*%(.-%)%s*", "")
    clean_name = clean_name:match("^%s*(.-)%s*$") or clean_name  -- trim
    local paren_content = name_lower:match("%((.-)%)")

    terms[#terms + 1] = (#clean_name > 2) and clean_name or name_lower

    if paren_content and #paren_content > 2 then
        terms[#terms + 1] = paren_content
    end

    local item_aliases = ensure_array(item.aliases)
    if item_aliases then
        for _idx, alias in ipairs(item_aliases) do
            if #alias > 2 then
                terms[#terms + 1] = alias:lower()
            end
        end
    end

    -- Collect all match spans from all terms
    local all_spans = {}
    for _idx, term in ipairs(terms) do
        local spans = XrayParser._collectMatchSpans(text_lower, term)
        for _idx2, span in ipairs(spans) do
            all_spans[#all_spans + 1] = span
        end
    end

    if #all_spans == 0 then return 0 end
    if #all_spans == 1 then return 1 end

    -- Sort by start position
    table.sort(all_spans, function(a, b)
        return a[1] < b[1]
    end)

    -- Merge overlapping spans and count unique matches
    local count = 1
    local current_end = all_spans[1][2]
    for i = 2, #all_spans do
        if all_spans[i][1] > current_end then
            -- No overlap: new distinct match
            count = count + 1
            current_end = all_spans[i][2]
        elseif all_spans[i][2] > current_end then
            -- Overlapping: extend current span (don't increment count)
            current_end = all_spans[i][2]
        end
    end

    return count
end

--- Singleton categories not useful for chapter text matching
local SINGLETON_CATEGORIES = {
    current_state = true,
    current_position = true,
    reader_engagement = true,
    conclusion = true,
}

--- Categories excluded from chapter text matching
--- Event-based categories have descriptive phrases as "names" (not searchable entity names),
--- which produces misleading counts (e.g., "Chapter 5 describes..." matching common words)
local TEXT_MATCH_EXCLUDED = {
    current_state = true,
    current_position = true,
    reader_engagement = true,
    conclusion = true,
    argument_development = true,
    timeline = true,
}

--- Resolve a connection/reference string to any X-Ray item
--- Searches all categories: characters, locations, concepts, themes, etc.
--- Connection strings follow the format "Name (relationship)" or just "Name"
--- @param data table Parsed X-Ray data
--- @param connection_string string e.g. "Elizabeth Bennet (love interest)" or "Constantinople"
--- @return table|nil result { item, category_key, name_portion, relationship } or nil if not found
function XrayParser.resolveConnection(data, connection_string)
    if not connection_string or connection_string == "" then return nil end

    -- Extract name portion: everything before the last " (" or the whole string
    local name_portion = connection_string:match("^(.-)%s*%(") or connection_string
    name_portion = name_portion:match("^%s*(.-)%s*$")  -- trim

    -- Extract relationship if present
    local relationship = connection_string:match("%((.-)%)")

    if not name_portion or name_portion == "" then return nil end

    local categories = XrayParser.getCategories(data)
    local name_lower = name_portion:lower()

    -- Build flat list of searchable items with their category keys
    -- Skip singleton categories (current_state, current_position, reader_engagement)
    local searchable = {}
    for _idx, cat in ipairs(categories) do
        if not SINGLETON_CATEGORIES[cat.key] then
            for _idx2, item in ipairs(cat.items) do
                table.insert(searchable, { item = item, category_key = cat.key })
            end
        end
    end

    if #searchable == 0 then return nil end

    -- Pass 1: exact name match (name, term, or event)
    for _idx, entry in ipairs(searchable) do
        local item_name = getItemSearchName(entry.item)
        if item_name and item_name:lower() == name_lower then
            return { item = entry.item, category_key = entry.category_key,
                     name_portion = name_portion, relationship = relationship }
        end
    end

    -- Pass 2: alias match (characters/key_figures only)
    for _idx, entry in ipairs(searchable) do
        local aliases = ensure_array(entry.item.aliases)
        if aliases then
            for _idx2, alias in ipairs(aliases) do
                if alias:lower() == name_lower then
                    return { item = entry.item, category_key = entry.category_key,
                             name_portion = name_portion, relationship = relationship }
                end
            end
        end
    end

    -- Pass 3: substring match on name (e.g., "Elizabeth" matches "Elizabeth Bennet")
    for _idx, entry in ipairs(searchable) do
        local item_name = getItemSearchName(entry.item)
        if item_name and item_name:lower():find(name_lower, 1, true) then
            return { item = entry.item, category_key = entry.category_key,
                     name_portion = name_portion, relationship = relationship }
        end
    end

    return nil
end

--- Get category definitions for building menus
--- @param data table Parsed X-Ray data
--- @return table categories Array of {key, label, items, singular_label}
function XrayParser.getCategories(data)
    if XrayParser.isFiction(data) then
        local cats = {
            { key = "characters",    label = _("Cast"),          items = data.characters or {} },
            { key = "locations",     label = _("World"),         items = data.locations or {} },
            { key = "themes",        label = _("Ideas"),         items = data.themes or {} },
            { key = "lexicon",       label = _("Lexicon"),       items = data.lexicon or {} },
            { key = "timeline",      label = _("Story Arc"),     items = data.timeline or {} },
        }
        if data.reader_engagement then
            table.insert(cats, { key = "reader_engagement", label = _("Reader Engagement"), items = { data.reader_engagement } })
        end
        -- Complete X-Ray uses conclusion; incremental uses current_state
        if data.conclusion then
            table.insert(cats, { key = "conclusion", label = _("Conclusion"), items = { data.conclusion } })
        elseif data.current_state then
            table.insert(cats, { key = "current_state", label = _("Current State"), items = { data.current_state } })
        end
        return cats
    else
        local cats = {
            { key = "key_figures",          label = _("Key Figures"),          items = data.key_figures or {} },
            { key = "locations",            label = _("Locations"),            items = data.locations or {} },
            { key = "core_concepts",        label = _("Core Concepts"),        items = data.core_concepts or {} },
            { key = "arguments",            label = _("Arguments"),            items = data.arguments or {} },
            { key = "terminology",          label = _("Terminology"),          items = data.terminology or {} },
            { key = "argument_development", label = _("Argument Development"), items = data.argument_development or {} },
        }
        if data.reader_engagement then
            table.insert(cats, { key = "reader_engagement", label = _("Reader Engagement"), items = { data.reader_engagement } })
        end
        -- Complete X-Ray uses conclusion; incremental uses current_position
        if data.conclusion then
            table.insert(cats, { key = "conclusion", label = _("Conclusion"), items = { data.conclusion } })
        elseif data.current_position then
            table.insert(cats, { key = "current_position", label = _("Current Position"), items = { data.current_position } })
        end
        return cats
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
    if category_key == "reader_engagement" then
        return _("Reader Engagement")
    end
    if category_key == "conclusion" then
        return _("Conclusion")
    end
    return item.name or _("Unknown")
end

--- Merge user-defined aliases into parsed X-Ray data (mutates in place)
--- @param data table Parsed X-Ray data
--- @param user_aliases table Mapping of item name → array of alias strings
--- @return table data The mutated data (for chaining)
function XrayParser.mergeUserAliases(data, user_aliases)
    if not user_aliases or not next(user_aliases) then
        return data
    end
    if not data or type(data) ~= "table" then
        return data
    end

    -- Build case-insensitive lookup: name_lower → { add = {...}, ignore = {...} }
    local lookup = {}
    for name, entry in pairs(user_aliases) do
        if name and type(entry) == "table" then
            local add = entry.add or {}
            local ignore = entry.ignore or {}
            if #add > 0 or #ignore > 0 then
                lookup[name:lower()] = entry
            end
        end
    end
    if not next(lookup) then return data end

    local categories = XrayParser.getCategories(data)
    for _idx, cat in ipairs(categories) do
        for _idx2, item in ipairs(cat.items) do
            local item_name = XrayParser.getItemName(item, cat.key)
            if item_name then
                local user_entry = lookup[item_name:lower()]
                if user_entry then
                    local existing = ensure_array(item.aliases) or {}

                    -- Build ignore set (case-insensitive)
                    local ignore_set = {}
                    for _idx3, ignored in ipairs(user_entry.ignore or {}) do
                        ignore_set[ignored:lower()] = true
                    end

                    -- Remove ignored aliases
                    if next(ignore_set) then
                        local filtered = {}
                        for _idx3, alias in ipairs(existing) do
                            if not ignore_set[alias:lower()] then
                                table.insert(filtered, alias)
                            end
                        end
                        existing = filtered
                    end

                    -- Add user aliases (dedup, case-insensitive)
                    local existing_lower = {}
                    for _idx3, alias in ipairs(existing) do
                        existing_lower[alias:lower()] = true
                    end
                    for _idx3, user_alias in ipairs(user_entry.add or {}) do
                        if not existing_lower[user_alias:lower()] then
                            table.insert(existing, user_alias)
                            existing_lower[user_alias:lower()] = true
                        end
                    end

                    item.aliases = existing
                end
            end
        end
    end

    return data
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
    if category_key == "reader_engagement" then
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

        local aliases = ensure_array(item.aliases)
        if aliases and #aliases > 0 then
            table.insert(parts, _("Also known as:") .. " " .. table.concat(aliases, ", "))
            table.insert(parts, "")
        end

        if item.description and item.description ~= "" then
            table.insert(parts, item.description)
            table.insert(parts, "")
        end

        local connections = ensure_array(item.connections)
        if connections and #connections > 0 then
            table.insert(parts, _("Connections:") .. " " .. table.concat(connections, ", "))
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
            table.insert(parts, "")
        end
        local refs = ensure_array(item.references)
        if refs and #refs > 0 then
            table.insert(parts, _("References:") .. " " .. table.concat(refs, ", "))
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
            table.insert(parts, "")
        end
        local refs = ensure_array(item.references)
        if refs and #refs > 0 then
            table.insert(parts, _("References:") .. " " .. table.concat(refs, ", "))
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
        local characters = ensure_array(item.characters) or ensure_array(item.references)
        if characters and #characters > 0 then
            table.insert(parts, _("Characters:") .. " " .. table.concat(characters, ", "))
        end

    elseif category_key == "reader_engagement" then
        if item.patterns and item.patterns ~= "" then
            table.insert(parts, _("Patterns:") .. " " .. item.patterns)
            table.insert(parts, "")
        end
        local notable = ensure_array(item.notable_highlights)
        if notable then
            table.insert(parts, _("Notable highlights:"))
            for _idx, h in ipairs(notable) do
                if type(h) == "table" then
                    local passage = h.passage or ""
                    local why = h.why_notable or ""
                    if passage ~= "" then
                        table.insert(parts, "- \"" .. passage .. "\"")
                        if why ~= "" then
                            table.insert(parts, "  " .. why)
                        end
                    end
                elseif type(h) == "string" and h ~= "" then
                    table.insert(parts, "- " .. h)
                end
            end
            table.insert(parts, "")
        end
        if item.connections and item.connections ~= "" then
            table.insert(parts, _("Connections:") .. " " .. item.connections)
        end

    elseif category_key == "current_state" or category_key == "current_position" then
        if item.summary and item.summary ~= "" then
            table.insert(parts, item.summary)
            table.insert(parts, "")
        end
        local conflicts = ensure_array(item.conflicts)
        if conflicts and #conflicts > 0 then
            table.insert(parts, _("Active conflicts:"))
            for _idx, c in ipairs(conflicts) do
                table.insert(parts, "- " .. c)
            end
            table.insert(parts, "")
        end
        local questions = ensure_array(item.questions) or ensure_array(item.questions_addressed)
        if questions and #questions > 0 then
            local label = category_key == "current_position"
                and _("Questions addressed:") or _("Unanswered questions:")
            table.insert(parts, label)
            for _idx, q in ipairs(questions) do
                table.insert(parts, "- " .. q)
            end
            table.insert(parts, "")
        end
        local building = ensure_array(item.building_toward)
        if building and #building > 0 then
            table.insert(parts, _("Building toward:"))
            for _idx, b in ipairs(building) do
                table.insert(parts, "- " .. b)
            end
        end

    elseif category_key == "conclusion" then
        if item.summary and item.summary ~= "" then
            table.insert(parts, item.summary)
            table.insert(parts, "")
        end
        -- Fiction fields
        local resolutions = ensure_array(item.resolutions)
        if resolutions and #resolutions > 0 then
            table.insert(parts, _("Resolutions:"))
            for _idx, r in ipairs(resolutions) do
                table.insert(parts, "- " .. r)
            end
            table.insert(parts, "")
        end
        local themes_resolved = ensure_array(item.themes_resolved)
        if themes_resolved and #themes_resolved > 0 then
            table.insert(parts, _("Themes resolved:"))
            for _idx, t in ipairs(themes_resolved) do
                table.insert(parts, "- " .. t)
            end
            table.insert(parts, "")
        end
        -- Non-fiction fields
        local key_findings = ensure_array(item.key_findings)
        if key_findings and #key_findings > 0 then
            table.insert(parts, _("Key findings:"))
            for _idx, f in ipairs(key_findings) do
                table.insert(parts, "- " .. f)
            end
            table.insert(parts, "")
        end
        local implications = ensure_array(item.implications)
        if implications and #implications > 0 then
            table.insert(parts, _("Implications:"))
            for _idx, i in ipairs(implications) do
                table.insert(parts, "- " .. i)
            end
            table.insert(parts, "")
        end
    end

    -- Show aliases for any category that has them (characters/key_figures handle it above)
    if category_key ~= "characters" and category_key ~= "key_figures" then
        local aliases = ensure_array(item.aliases)
        if aliases and #aliases > 0 then
            table.insert(parts, "")
            table.insert(parts, _("Also known as:") .. " " .. table.concat(aliases, ", "))
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
        if progress == "Complete" or progress == "100%" then
            header = header .. " (Complete)"
        else
            header = header .. " (Through " .. progress .. ")"
        end
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

            if cat.key == "current_state" or cat.key == "current_position" or cat.key == "conclusion" then
                -- Current state / conclusion: render inline
                local state = cat.items[1]
                if state.summary and state.summary ~= "" then
                    table.insert(lines, state.summary)
                    table.insert(lines, "")
                end
                -- current_state fields
                local s_conflicts = ensure_array(state.conflicts)
                if s_conflicts and #s_conflicts > 0 then
                    for _idx2, c in ipairs(s_conflicts) do
                        table.insert(lines, "- " .. c)
                    end
                    table.insert(lines, "")
                end
                local s_questions = ensure_array(state.questions) or ensure_array(state.questions_addressed)
                if s_questions and #s_questions > 0 then
                    for _idx2, q in ipairs(s_questions) do
                        table.insert(lines, "- " .. q)
                    end
                    table.insert(lines, "")
                end
                local s_building = ensure_array(state.building_toward)
                if s_building and #s_building > 0 then
                    for _idx2, b in ipairs(s_building) do
                        table.insert(lines, "- " .. b)
                    end
                    table.insert(lines, "")
                end
                -- conclusion fields (fiction)
                local s_resolutions = ensure_array(state.resolutions)
                if s_resolutions and #s_resolutions > 0 then
                    for _idx2, r in ipairs(s_resolutions) do
                        table.insert(lines, "- " .. r)
                    end
                    table.insert(lines, "")
                end
                local s_themes = ensure_array(state.themes_resolved)
                if s_themes and #s_themes > 0 then
                    for _idx2, t in ipairs(s_themes) do
                        table.insert(lines, "- " .. t)
                    end
                    table.insert(lines, "")
                end
                -- conclusion fields (non-fiction)
                local s_findings = ensure_array(state.key_findings)
                if s_findings and #s_findings > 0 then
                    for _idx2, f in ipairs(s_findings) do
                        table.insert(lines, "- " .. f)
                    end
                    table.insert(lines, "")
                end
                local s_implications = ensure_array(state.implications)
                if s_implications and #s_implications > 0 then
                    for _idx2, i in ipairs(s_implications) do
                        table.insert(lines, "- " .. i)
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

                    local c_aliases = ensure_array(char.aliases)
                    if c_aliases and #c_aliases > 0 then
                        table.insert(lines, "*(Also known as: " .. table.concat(c_aliases, ", ") .. ")*")
                    end
                    local c_connections = ensure_array(char.connections)
                    if c_connections and #c_connections > 0 then
                        table.insert(lines, "*Connections: " .. table.concat(c_connections, ", ") .. "*")
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
                    local l_refs = ensure_array(loc.references)
                    if l_refs and #l_refs > 0 then
                        table.insert(lines, "*References: " .. table.concat(l_refs, ", ") .. "*")
                    end
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
                    local t_refs = ensure_array(theme.references)
                    if t_refs and #t_refs > 0 then
                        table.insert(lines, "*References: " .. table.concat(t_refs, ", ") .. "*")
                    end
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
                    local e_characters = ensure_array(event.characters) or ensure_array(event.references)
                    if e_characters and #e_characters > 0 then
                        entry = entry .. " [" .. table.concat(e_characters, ", ") .. "]"
                    end
                    table.insert(lines, "- " .. entry)
                end
                table.insert(lines, "")
            elseif cat.key == "reader_engagement" then
                local engagement = cat.items[1]
                if engagement.patterns and engagement.patterns ~= "" then
                    table.insert(lines, engagement.patterns)
                    table.insert(lines, "")
                end
                local r_notable = ensure_array(engagement.notable_highlights)
                if r_notable and #r_notable > 0 then
                    for _idx2, h in ipairs(r_notable) do
                        if type(h) == "table" then
                            local passage = h.passage or ""
                            local why = h.why_notable or ""
                            if passage ~= "" then
                                table.insert(lines, "- \"" .. passage .. "\"")
                                if why ~= "" then
                                    table.insert(lines, "  " .. why)
                                end
                            end
                        elseif type(h) == "string" and h ~= "" then
                            table.insert(lines, "- " .. h)
                        end
                    end
                    table.insert(lines, "")
                end
                if engagement.connections and engagement.connections ~= "" then
                    table.insert(lines, "*" .. engagement.connections .. "*")
                    table.insert(lines, "")
                end
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
        local s_aliases = ensure_array(char.aliases)
        if not match_field and s_aliases then
            for _idx2, alias in ipairs(s_aliases) do
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
        -- Skip singleton categories (not useful in search)
        if cat.key ~= "current_state" and cat.key ~= "current_position"
            and cat.key ~= "reader_engagement" and cat.key ~= "conclusion" then
            for _idx2, item in ipairs(cat.items) do
                local match_field = nil
                -- Check primary name/term/event
                local name = item.name or item.term or item.event or ""
                if name ~= "" and name:lower():find(query_lower, 1, true) then
                    match_field = "name"
                end
                -- Check aliases
                local i_aliases = ensure_array(item.aliases)
                if not match_field and i_aliases then
                    for _idx3, alias in ipairs(i_aliases) do
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

--- Find all X-Ray items appearing in chapter text
--- @param data table Parsed X-Ray data
--- @param chapter_text string The chapter text content
--- @return table results Array of {item, category_key, category_label, count} sorted by count desc
function XrayParser.findItemsInChapter(data, chapter_text)
    if not chapter_text or chapter_text == "" then return {} end

    local categories = XrayParser.getCategories(data)
    if not categories or #categories == 0 then return {} end

    local text_lower = chapter_text:lower()
    local results = {}

    for _idx, cat in ipairs(categories) do
        if not TEXT_MATCH_EXCLUDED[cat.key] then
            for _idx2, item in ipairs(cat.items) do
                local count = XrayParser.countItemOccurrences(item, text_lower)
                if count > 0 then
                    table.insert(results, {
                        item = item,
                        category_key = cat.key,
                        category_label = cat.label,
                        count = count,
                    })
                end
            end
        end
    end

    -- Sort by mention count descending
    table.sort(results, function(a, b)
        return a.count > b.count
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
        local best_count = XrayParser.countItemOccurrences(char, text_lower)
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

--- Check if an ASCII byte is a word character (letter or digit).
--- @param b number Byte value (must be < 128)
--- @return boolean
local function isAsciiWordByte(b)
    if b >= 48 and b <= 57 then return true end   -- 0-9
    if b >= 65 and b <= 90 then return true end   -- A-Z
    if b >= 97 and b <= 122 then return true end  -- a-z
    return false
end

--- Check if the character at a text position is a word character for boundary detection.
--- For ASCII bytes: checks letters and digits.
--- For multi-byte UTF-8: decodes the codepoint and checks known non-word ranges
--- (General Punctuation, Latin-1 symbols, CJK symbols, etc.).
--- @param text string The text
--- @param pos number Byte position to check
--- @param scan_back boolean If true, pos may be a continuation byte (last byte of preceding
---   character); scans back up to 3 bytes to find the leading byte and decode.
--- @return boolean true if it's a word character
local function isWordCharAt(text, pos, scan_back)
    local b = text:byte(pos)
    if not b then return false end

    -- ASCII: simple byte check
    if b < 128 then return isAsciiWordByte(b) end

    -- Multi-byte UTF-8: find the leading byte
    local lead_pos = pos
    if scan_back and b < 0xC0 then
        -- Continuation byte (0x80-0xBF): scan back to find leading byte
        for i = 1, 3 do
            local p = pos - i
            if p < 1 then return true end  -- Can't decode, assume word
            local pb = text:byte(p)
            if pb >= 0xC0 then lead_pos = p; break end
            if pb < 0x80 then return true end  -- Hit ASCII, malformed; assume word
        end
    end

    -- Decode codepoint from leading byte
    local lb = text:byte(lead_pos)
    if not lb or lb < 0xC0 then return true end  -- Can't decode, assume word
    local cp
    if lb < 0xE0 then
        -- 2-byte: U+0080-U+07FF (Latin Extended, Cyrillic, Arabic, Hebrew, etc.)
        local b2 = text:byte(lead_pos + 1)
        if not b2 then return true end
        cp = (lb - 0xC0) * 64 + (b2 - 0x80)
    elseif lb < 0xF0 then
        -- 3-byte: U+0800-U+FFFF (CJK, General Punctuation, symbols, etc.)
        local b2, b3 = text:byte(lead_pos + 1), text:byte(lead_pos + 2)
        if not b2 or not b3 then return true end
        cp = (lb - 0xE0) * 4096 + (b2 - 0x80) * 64 + (b3 - 0x80)
    else
        -- 4-byte: emoji/supplementary — treat as non-word boundary
        return false
    end

    -- Check known non-word Unicode ranges (punctuation, symbols, spaces)
    if cp >= 0x2000 and cp <= 0x206F then return false end  -- General Punctuation (smart quotes, dashes, ellipsis)
    if cp >= 0x00A0 and cp <= 0x00BF then return false end  -- Latin-1 symbols (guillemets, ©, etc.)
    if cp >= 0x2E00 and cp <= 0x2E7F then return false end  -- Supplemental Punctuation
    if cp >= 0x3000 and cp <= 0x303F then return false end  -- CJK Symbols and Punctuation

    -- Everything else (accented letters, Cyrillic, Greek, etc.): word character
    return true
end

--- Check if needle should skip word-boundary checking.
--- Returns true for scripts where byte-level boundary detection is unreliable:
--- - CJK/Thai (3+ byte UTF-8, leading byte >= 0xE0): no word-boundary spaces
--- - Arabic/Hebrew/Syriac (2-byte UTF-8, leading bytes 0xD6-0xDB): have spaces but
---   multi-byte punctuation (،؛؟) makes byte-level boundary check unreliable
--- Latin/Cyrillic/Greek (leading bytes 0xC0-0xD5) still use boundary checking.
--- @param str string Text to check
--- @return boolean
local function skipBoundaryCheck(str)
    for i = 1, #str do
        local b = str:byte(i)
        if b >= 0xE0 then return true end           -- CJK, Thai, etc.
        if b >= 0xD6 and b <= 0xDB then return true end  -- Arabic, Hebrew, Syriac
    end
    return false
end

--- Collect match spans of a substring in text (plain search).
--- For Latin/Cyrillic/Greek: uses word-boundary matching to prevent false positives.
--- For CJK/Thai/Arabic/Hebrew: skips boundary matching (see skipBoundaryCheck).
--- @param text string Haystack (already lowered)
--- @param needle string Needle (already lowered)
--- @return table spans Array of {start, end_pos} pairs
function XrayParser._collectMatchSpans(text, needle)
    local spans = {}
    local pos = 1
    local needle_len = #needle
    local text_len = #text
    local skip_boundaries = skipBoundaryCheck(needle)
    while true do
        local start = text:find(needle, pos, true)
        if not start then break end
        local end_pos = start + needle_len - 1
        if skip_boundaries then
            spans[#spans + 1] = {start, end_pos}
        else
            -- Check word boundaries: character before/after must be non-word
            local before_ok = (start == 1) or not isWordCharAt(text, start - 1, true)
            local after_ok = (end_pos >= text_len) or not isWordCharAt(text, end_pos + 1, false)
            if before_ok and after_ok then
                spans[#spans + 1] = {start, end_pos}
            end
        end
        pos = start + needle_len
    end
    return spans
end

--- Count occurrences of a substring in text (convenience wrapper).
--- @param text string Haystack (already lowered)
--- @param needle string Needle (already lowered)
--- @return number count
function XrayParser._countOccurrences(text, needle)
    return #XrayParser._collectMatchSpans(text, needle)
end

--- Build a compact entity index listing existing names per category.
--- Used in update prompts so the AI uses exact matching strings for existing entities.
--- @param data table Parsed X-Ray data
--- @return string index Multi-line string: "category: Name1 (alias1, alias2); Name2\n..."
function XrayParser.buildEntityIndex(data)
    local categories = XrayParser.getCategories(data)
    if not categories or #categories == 0 then return "" end

    local lines = {}
    for _idx, cat in ipairs(categories) do
        if not SINGLETON_CATEGORIES[cat.key] and cat.items and #cat.items > 0 then
            local names = {}
            for _idx2, item in ipairs(cat.items) do
                local name = getItemSearchName(item)
                if name then
                    local item_aliases = ensure_array(item.aliases)
                    if item_aliases and #item_aliases > 0 then
                        local shown = {}
                        for i = 1, math.min(2, #item_aliases) do
                            shown[i] = item_aliases[i]
                        end
                        name = name .. " (" .. table.concat(shown, ", ") .. ")"
                    end
                    names[#names + 1] = name
                end
            end
            if #names > 0 then
                lines[#lines + 1] = cat.key .. ": " .. table.concat(names, "; ")
            end
        end
    end
    return table.concat(lines, "\n")
end

--- Categories where items use descriptive phrases as names (not stable identifiers).
--- These use pure append during merge instead of name-based matching.
local APPEND_CATEGORIES = {
    timeline = true,
    argument_development = true,
}

--- Merge array category items by name matching (case-insensitive).
--- Matching items are replaced in-place; new items are appended.
--- @param old_items table Existing items array (mutated)
--- @param new_items table New items to merge in
--- @return table old_items The merged array
local function mergeArrayCategory(old_items, new_items)
    local lookup = {}
    for i, item in ipairs(old_items) do
        local name = getItemSearchName(item)
        if name then
            lookup[name:lower()] = i
        end
    end
    for _idx, new_item in ipairs(new_items) do
        local name = getItemSearchName(new_item)
        local idx = name and lookup[name:lower()]
        if idx then
            old_items[idx] = new_item
        else
            old_items[#old_items + 1] = new_item
        end
    end
    return old_items
end

--- Append new items to old items without deduplication.
--- Used for timeline/argument_development where names are full sentences.
--- @param old_items table Existing items array (mutated)
--- @param new_items table New items to append
--- @return table old_items The extended array
local function appendCategory(old_items, new_items)
    for _idx, item in ipairs(new_items) do
        old_items[#old_items + 1] = item
    end
    return old_items
end

--- Merge partial X-Ray update into existing data.
--- The AI outputs only new/changed entries; this merges them into the full dataset.
--- @param old_data table Complete existing X-Ray data (mutated in place)
--- @param new_data table Partial update from AI
--- @return table old_data The merged result
function XrayParser.merge(old_data, new_data)
    if not new_data or type(new_data) ~= "table" then return old_data end
    if not old_data or type(old_data) ~= "table" then return new_data end

    old_data.type = old_data.type or new_data.type

    local keys = XrayParser.isFiction(old_data) and FICTION_KEYS or NONFICTION_KEYS
    for _idx, key in ipairs(keys) do
        if new_data[key] ~= nil then
            if SINGLETON_CATEGORIES[key] then
                old_data[key] = new_data[key]
            elseif APPEND_CATEGORIES[key] then
                if type(new_data[key]) == "table" and #new_data[key] > 0 then
                    old_data[key] = appendCategory(old_data[key] or {}, new_data[key])
                end
            else
                if type(new_data[key]) == "table" then
                    old_data[key] = mergeArrayCategory(old_data[key] or {}, new_data[key])
                end
            end
        end
    end

    return old_data
end

return XrayParser
