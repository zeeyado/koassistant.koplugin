--[[--
Notebook module for KOAssistant - Per-book markdown notebooks

Handles:
- Notebook file path resolution (sidecar or vault/central folder)
- Page/chapter info extraction
- Entry formatting (Q+A with highlighted text)
- Appending entries to notebook files
- File stats for indexing
- YAML frontmatter for vault mode (Obsidian integration)

@module koassistant_notebook
]]

local DocSettings = require("docsettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Notebook = {}

--- Check alternate storage mode locations for a sidecar file (lazy migration on mode switch)
--- @param document_path string The document file path
--- @param current_path string The expected path in current storage mode
--- @param filename string The sidecar filename
--- @return boolean migrated Whether a file was migrated to current_path
local function migrateSidecarIfNeeded(document_path, current_path, filename)
    local current = G_reader_settings:readSetting("document_metadata_folder", "doc")
    local alternates = { "doc", "dir" }
    if DocSettings.isHashLocationEnabled() then
        table.insert(alternates, "hash")
    end
    for _idx, loc in ipairs(alternates) do
        if loc ~= current then
            local alt_dir = DocSettings:getSidecarDir(document_path, loc)
            local alt_path = alt_dir .. "/" .. filename
            if lfs.attributes(alt_path, "mode") == "file" then
                local util = require("util")
                local dir = current_path:match("(.*/)") or ""
                if dir ~= "" then util.makePath(dir) end
                local ok, err = os.rename(alt_path, current_path)
                if ok then
                    logger.info("KOAssistant: Migrated sidecar file", filename, "from alternate storage location")
                    return true
                else
                    logger.warn("KOAssistant: Failed to migrate sidecar file", filename, ":", err)
                end
            end
        end
    end
    return false
end

-- Sanitize a string for use as a filename
-- Strips filesystem-unsafe characters, control chars, collapses whitespace
-- @param name string Raw name string
-- @return string|nil Sanitized name, or nil if empty
local function sanitizeFilename(name)
    if not name or name == "" then return nil end
    -- Strip filesystem-unsafe characters: <>:"/\|?* and control chars
    local safe = name:gsub('[<>:"/\\|%?%*]', "")
    safe = safe:gsub("%c", "")
    -- Collapse whitespace
    safe = safe:gsub("%s+", " ")
    -- Trim
    safe = safe:match("^%s*(.-)%s*$")
    if not safe or safe == "" then return nil end
    return safe
end

-- Quote a string for YAML value (handles colons, special chars)
-- @param str string Raw string
-- @return string Quoted YAML value
local function yamlQuote(str)
    return '"' .. str:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

--- Get the base directory for vault/central notebook storage
--- @param features table|nil Plugin features settings (reads from G_reader_settings if nil)
--- @return string|nil base_dir The base directory path, or nil for sidecar mode
function Notebook.getBaseDir(features)
    if not features then
        features = G_reader_settings:readSetting("features") or {}
    end
    local location = features.notebook_save_location or "sidecar"
    if location == "sidecar" then return nil end
    if location == "central" then
        local DataStorage = require("datastorage")
        return DataStorage:getDataDir() .. "/koassistant_notebooks"
    end
    -- custom
    return features.notebook_custom_path
end

--- Generate a filename for a notebook in vault/central mode
--- Pattern: Author — Title.md (em dash separator)
--- @param document_path string The document file path
--- @param doc_props table|nil Pre-loaded doc_props (avoids re-opening DocSettings)
--- @return string filename The generated filename (e.g. "Dostoevsky — Crime and Punishment.md")
function Notebook.generateFilename(document_path, doc_props)
    if not doc_props then
        local doc_settings = DocSettings:open(document_path)
        doc_props = doc_settings:readSetting("doc_props")
    end

    local title = doc_props and (doc_props.display_title or doc_props.title) or nil
    local author = doc_props and doc_props.authors or nil

    local safe_title = sanitizeFilename(title)
    local safe_author = sanitizeFilename(author)

    local stem
    if safe_author and safe_title then
        stem = safe_author .. " \u{2014} " .. safe_title  -- em dash
    elseif safe_title then
        stem = safe_title
    else
        -- Fallback to filename without extension
        stem = document_path:match("([^/]+)%.[^%.]+$") or "Notebook"
    end

    -- Length cap
    if #stem > 100 then
        stem = stem:sub(1, 100)
    end

    return stem .. ".md"
end

--- Generate YAML frontmatter for a notebook file (vault/central mode only)
--- Minimal fields for Obsidian compatibility and relinking
--- @param document_path string The document file path
--- @param doc_props table|nil Pre-loaded doc_props (avoids re-opening DocSettings)
--- @return string frontmatter The YAML frontmatter block including trailing newline
function Notebook.generateFrontmatter(document_path, doc_props)
    if not doc_props then
        local doc_settings = DocSettings:open(document_path)
        doc_props = doc_settings:readSetting("doc_props")
    end

    local parts = {"---"}

    local title = doc_props and (doc_props.display_title or doc_props.title) or nil
    if title and title ~= "" then
        table.insert(parts, "title: " .. yamlQuote(title))
    end

    local author = doc_props and doc_props.authors or nil
    if author and author ~= "" then
        table.insert(parts, "author: " .. yamlQuote(author))
    end

    table.insert(parts, "book_path: " .. yamlQuote(document_path))
    table.insert(parts, "created: " .. os.date("%Y-%m-%d"))
    table.insert(parts, "---")
    table.insert(parts, "")

    return table.concat(parts, "\n")
end

-- Helper to strip message_builder labels from content
-- Removes [Context], [Request], [Additional user input] structural labels
-- @param content string Raw message content
-- @return string Cleaned content without labels
local function cleanMessageContent(content)
    if not content then return nil end
    -- Remove [Context], [Request], [Additional user input] labels
    local cleaned = content:gsub("%[Context%]%s*", "")
    cleaned = cleaned:gsub("%[Request%]%s*", "")
    cleaned = cleaned:gsub("%[Additional user input%]%s*", "")
    -- Trim leading/trailing whitespace
    return cleaned:match("^%s*(.-)%s*$")
end

-- Helper to extract just the user's additional input (follow-up question)
-- Returns nil if no additional input was provided
-- Handles both predefined actions ([Additional user input]) and Ask action ([User Question])
-- @param content string Raw user message content
-- @return string|nil The additional input text, or nil if none
local function extractAdditionalInput(content)
    if not content then return nil end
    -- Try both label formats:
    -- - [Additional user input] - used by predefined actions (ELI5, Explain, etc.)
    -- - [User Question] - used by Ask action
    local labels = {"%[Additional user input%]", "%[User Question%]"}
    for _idx, label in ipairs(labels) do
        local label_start, label_end = content:find(label)
        if label_start then
            local after_label = content:sub(label_end + 1)
            -- Trim leading/trailing whitespace (including newlines)
            local trimmed = after_label:match("^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" then
                return trimmed
            end
        end
    end
    return nil
end

-- Helper to extract selected text from context message
-- Handles format: Selected text:\n"the actual text"
-- @param content string Raw context message content
-- @return string|nil The selected text, or nil if not found
local function extractSelectedText(content)
    if not content then return nil end
    -- Look for 'Selected text:' followed by quoted text on next line
    -- Pattern: Selected text:\n"..."
    local start_pos = content:find("Selected text:")
    if start_pos then
        local after_label = content:sub(start_pos + 14)  -- 14 = length of "Selected text:"
        -- Look for quoted text (handles both single line and multi-line)
        local quoted = after_label:match('^%s*"(.-)"')
        if quoted and quoted ~= "" then
            return quoted
        end
    end
    return nil
end

--- Get notebook file path for a document
--- Location-aware: resolves to sidecar, central, or custom folder based on settings
--- Returns nil for general/multi-book chats (no per-book context)
--- @param document_path string|nil The document file path
--- @return string|nil notebook_path The full path to the notebook file
function Notebook.getPath(document_path)
    if not document_path
        or document_path == "__GENERAL_CHATS__"
        or document_path == "__MULTI_BOOK_CHATS__" then
        return nil
    end

    local features = G_reader_settings:readSetting("features") or {}
    local location = features.notebook_save_location or "sidecar"

    if location == "sidecar" then
        local sidecar_dir = DocSettings:getSidecarDir(document_path)
        return sidecar_dir .. "/koassistant_notebook.md"
    end

    -- Vault/central mode
    local base_dir = Notebook.getBaseDir(features)
    if not base_dir then return nil end

    -- Fast path: check index for cached filename
    local index = G_reader_settings:readSetting("koassistant_notebook_index", {})
    local entry = index[document_path]
    if entry and entry.filename then
        return base_dir .. "/" .. entry.filename
    end

    -- Fallback: check DocSettings ref
    local doc_settings = DocSettings:open(document_path)
    local ref = doc_settings:readSetting("koassistant_notebook_ref")
    if ref and ref.filename then
        return base_dir .. "/" .. ref.filename
    end

    -- New notebook: generate filename (collision check happens in create())
    return base_dir .. "/" .. Notebook.generateFilename(document_path)
end

--- Check if notebook exists for a document
--- @param document_path string The document file path
--- @return boolean exists Whether the notebook file exists
function Notebook.exists(document_path)
    local path = Notebook.getPath(document_path)
    if not path then return false end
    local attr = lfs.attributes(path)
    if attr and attr.mode == "file" then return true end
    -- Lazy sidecar migration only applies in sidecar mode
    local features = G_reader_settings:readSetting("features") or {}
    if (features.notebook_save_location or "sidecar") == "sidecar" then
        return migrateSidecarIfNeeded(document_path, path, "koassistant_notebook.md")
    end
    return false
end

--- Get current page info from ReaderUI
--- Extracts page number, progress percentage, and chapter title
--- @param ui table|nil ReaderUI instance (optional, will use ReaderUI.instance if not provided)
--- @return table page_info Table with page, progress, chapter, timestamp fields
function Notebook.getPageInfo(ui)
    local info = {
        page = nil,
        total_pages = nil,
        progress = nil,
        chapter = nil,
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
    }

    -- Use passed ui or try to get from ReaderUI.instance
    local reader_ui = ui
    if not reader_ui then
        local ReaderUI = require("apps/reader/readerui")
        reader_ui = ReaderUI.instance
    end

    if reader_ui and reader_ui.document then
        -- Get total pages
        info.total_pages = reader_ui.document.info and reader_ui.document.info.number_of_pages

        -- Get page number (same pattern as context_extractor)
        if reader_ui.document.info.has_pages then
            -- PDF/page-based document
            info.page = reader_ui.view and reader_ui.view.state and reader_ui.view.state.page
        else
            -- EPUB/flowing document
            local xp = reader_ui.document:getXPointer()
            if xp then
                info.page = reader_ui.document:getPageFromXPointer(xp)
            end
        end

        -- Get progress percentage
        if info.page and info.total_pages and info.total_pages > 0 then
            info.progress = math.floor((info.page / info.total_pages) * 100)
        end

        -- Get chapter title from TOC
        if reader_ui.toc and info.page then
            info.chapter = reader_ui.toc:getTocTitleByPage(info.page)
        end
    end

    return info
end

--- Format a notebook entry
--- Creates a clean, readable markdown entry optimized for external editors (Obsidian, etc.)
---
--- Entry format (each section separated by blank line for markdown paragraph breaks):
---   **[2026-01-31 14:30:00]**
---
---   Page 42 (15%) • Chapter Title
---
---   **Explain** • claude-sonnet-4-20250514
---
---   **Highlighted:**
---   > The selected passage as blockquote
---
---   **User:** additional input (only if user typed something)
---
---   **KOAssistant:**
---   AI's response here
---
---   ---
---
--- Content tiers:
---   - response: Just the AI response
---   - qa: Highlighted text + user input (if any) + response
---   - full_qa: Same as qa (no book info - notebooks are book-specific)
---
--- @param data table Entry data: action_name, highlighted_text, follow_up, response, model_name
--- @param page_info table Page info from getPageInfo()
--- @param content_format string "response" | "qa" | "full_qa" (default: "qa")
--- @return string entry The formatted markdown entry
function Notebook.formatEntry(data, page_info, content_format)
    content_format = content_format or "qa"
    local parts = {}

    -- Line 1: Date and time (bold)
    table.insert(parts, "**[" .. page_info.timestamp .. "]**")
    table.insert(parts, "")  -- Blank line for markdown paragraph break

    -- Line 2: Page info and chapter (if available)
    local location_parts = {}
    if page_info.page then
        local page_str = "Page " .. page_info.page
        if page_info.progress then
            page_str = page_str .. " (" .. page_info.progress .. "%)"
        end
        table.insert(location_parts, page_str)
    end
    if page_info.chapter then
        table.insert(location_parts, page_info.chapter)
    end
    if #location_parts > 0 then
        table.insert(parts, table.concat(location_parts, " • "))
        table.insert(parts, "")  -- Blank line for markdown paragraph break
    end

    -- Line 3: Action name (bold) with optional model name
    local action_line = "**" .. (data.action_name or "KOAssistant Chat") .. "**"
    if data.model_name and data.model_name ~= "" then
        action_line = action_line .. " • " .. data.model_name
    end
    table.insert(parts, action_line)
    table.insert(parts, "")  -- Blank line before content

    -- Highlighted text as blockquote (qa and full_qa only)
    if content_format ~= "response" and data.highlighted_text and data.highlighted_text ~= "" then
        table.insert(parts, "**Highlighted:**")
        -- Convert newlines in highlighted text to blockquote continuation
        local quoted_text = "> " .. data.highlighted_text:gsub("\n", "\n> ")
        table.insert(parts, quoted_text)
        table.insert(parts, "")
    end

    -- User's additional input (only if provided)
    if content_format ~= "response" and data.follow_up and data.follow_up ~= "" then
        table.insert(parts, "**User:** " .. data.follow_up)
        table.insert(parts, "")
    end

    -- AI Response with label
    if data.response and data.response ~= "" then
        table.insert(parts, "**KOAssistant:**")
        table.insert(parts, data.response)
        table.insert(parts, "")
    end

    -- Entry separator
    table.insert(parts, "---")
    table.insert(parts, "")

    return table.concat(parts, "\n")
end

--- Append entry to notebook file
--- Creates sidecar directory if needed
--- @param notebook_path string Full path to the notebook file
--- @param entry string Formatted entry text to append
--- @return boolean success Whether the append succeeded
--- @return string|nil error Error message if failed
function Notebook.append(notebook_path, entry)
    if not notebook_path then
        return false, "No notebook path"
    end

    -- Ensure sidecar directory exists
    local util = require("util")
    local dir = notebook_path:match("(.*/)")
    if dir then
        util.makePath(dir)
    end

    local file, err = io.open(notebook_path, "a")
    if not file then
        logger.err("KOAssistant Notebook: Failed to open file:", err)
        return false, "Failed to open: " .. (err or "unknown")
    end

    file:write(entry)
    file:close()
    return true, nil
end

--- Save chat to notebook (convenience function)
--- Extracts Q+A from history and formats as notebook entry
--- Only includes follow-up if user typed additional input (not the full structured message)
--- @param document_path string The document file path
--- @param history table MessageHistory object
--- @param highlighted_text string|nil Selected text (if any)
--- @param ui table|nil ReaderUI instance
--- @param content_format string|nil "response" | "qa" | "full_qa" (default: "qa")
--- @param model_name string|nil Model name to include in entry (e.g. "claude-sonnet-4-20250514")
--- @return boolean success Whether save succeeded
--- @return string|nil error Error message if failed
function Notebook.saveChat(document_path, history, highlighted_text, ui, content_format, model_name)
    local notebook_path = Notebook.getPath(document_path)
    if not notebook_path then
        return false, "No document open"
    end

    -- Auto-create notebook if it doesn't exist (ensures proper header/frontmatter)
    if not Notebook.exists(document_path) then
        local ok, err = Notebook.create(document_path)
        if not ok then return false, err end
        -- Re-resolve path (vault mode may have generated collision-safe name)
        notebook_path = Notebook.getPath(document_path)
        if not notebook_path then return false, "Failed to resolve notebook path" end
    end

    local page_info = Notebook.getPageInfo(ui)
    content_format = content_format or "qa"

    -- Extract messages from history
    -- The message structure is:
    --   1. Context user message (is_context=true): Contains [Context], [Request], and [Additional user input] sections
    --   2. Display user message (is_context=false, optional): Just the raw additional input (if any)
    --   3. Assistant message: The AI response
    -- We need to get [Additional user input] from the FIRST (context) user message
    local messages = history:getMessages() or {}
    local context_user_message, response = nil, nil

    for _idx, msg in ipairs(messages) do
        if msg.role == "user" then
            -- Get the FIRST user message (context one) which contains [Additional user input]
            if not context_user_message then
                context_user_message = msg.content
            end
        elseif msg.role == "assistant" then
            -- Get the last assistant response
            response = msg.content
        end
    end

    -- Extract only the user's additional input (follow-up question)
    -- This strips the [Context], [Request] labels that are meant for the AI
    local follow_up = extractAdditionalInput(context_user_message)

    -- Determine the actual highlighted text to use
    -- The passed highlighted_text might be:
    --   1. Actual selected text (good)
    --   2. Book metadata like 'Book: "Title" by Author' (from book context)
    --   3. nil (no selection)
    -- For case 2, try to extract actual selected text from context message
    local actual_highlighted = highlighted_text
    if highlighted_text then
        -- Check if it looks like book metadata rather than actual highlighted text
        local looks_like_metadata = highlighted_text:match("^Book:%s*\"") or
                                    highlighted_text:match("^From%s*\"")
        if looks_like_metadata then
            -- Try to extract actual selected text from context message
            local extracted = extractSelectedText(context_user_message)
            if extracted then
                actual_highlighted = extracted
            else
                -- It's just metadata with no selection, don't show as highlighted
                actual_highlighted = nil
            end
        end
    end

    local entry = Notebook.formatEntry({
        follow_up = follow_up,
        response = response or "",
        action_name = history.prompt_action,
        highlighted_text = actual_highlighted,
        model_name = model_name,
    }, page_info, content_format)

    return Notebook.append(notebook_path, entry)
end

--- Read notebook content
--- @param document_path string The document file path
--- @return string|nil content The notebook content or nil if not found
function Notebook.read(document_path)
    local path = Notebook.getPath(document_path)
    if not path then return nil end

    local file = io.open(path, "r")
    if not file then
        -- Lazy sidecar migration only applies in sidecar mode
        local features = G_reader_settings:readSetting("features") or {}
        if (features.notebook_save_location or "sidecar") == "sidecar" then
            if migrateSidecarIfNeeded(document_path, path, "koassistant_notebook.md") then
                file = io.open(path, "r")
            end
        end
        if not file then return nil end
    end

    local content = file:read("*all")
    file:close()
    return content
end

--- Get file stats for index
--- Includes filename field in vault/central mode for fast index lookups
--- @param document_path string The document file path
--- @return table|nil stats Table with size, modified, and optional filename
function Notebook.getStats(document_path)
    local path = Notebook.getPath(document_path)
    if not path then return nil end

    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil end

    local stats = {
        size = attr.size,
        modified = attr.modification,
    }

    -- Include filename for vault mode (enables fast path resolution in getPath)
    local features = G_reader_settings:readSetting("features") or {}
    if (features.notebook_save_location or "sidecar") ~= "sidecar" then
        stats.filename = path:match("([^/]+)$")
    end

    return stats
end

--- Create empty notebook with header (and frontmatter in vault mode)
--- In vault mode: generates filename with collision handling, stores DocSettings ref
--- @param document_path string The document file path
--- @return boolean success Whether creation succeeded
--- @return string|nil error Error message if failed
function Notebook.create(document_path)
    local features = G_reader_settings:readSetting("features") or {}
    local location = features.notebook_save_location or "sidecar"

    -- Get metadata (shared for frontmatter, header, filename)
    local doc_settings = DocSettings:open(document_path)
    local doc_props = doc_settings:readSetting("doc_props")

    local notebook_path, final_filename
    if location == "sidecar" then
        notebook_path = Notebook.getPath(document_path)
    else
        -- Vault mode: generate filename with collision handling
        local base_dir = Notebook.getBaseDir(features)
        if not base_dir then return false, "No notebook directory configured" end
        final_filename = Notebook.generateFilename(document_path, doc_props)
        notebook_path = base_dir .. "/" .. final_filename
        -- Handle filename collision
        local stem = final_filename:match("^(.+)%.md$") or final_filename
        local counter = 1
        while lfs.attributes(notebook_path, "mode") == "file" do
            counter = counter + 1
            final_filename = stem .. " (" .. counter .. ").md"
            notebook_path = base_dir .. "/" .. final_filename
        end
    end

    if not notebook_path then
        return false, "Invalid document path"
    end

    -- Build content
    local content_parts = {}

    -- YAML frontmatter (vault mode only)
    if location ~= "sidecar" then
        table.insert(content_parts, Notebook.generateFrontmatter(document_path, doc_props))
    end

    -- Book name for header
    local book_name = doc_props and (doc_props.display_title or doc_props.title) or nil
    if not book_name or book_name == "" then
        book_name = document_path:match("([^/]+)%.[^%.]+$") or "Unknown"
    end
    table.insert(content_parts, "# Notebook: " .. book_name .. "\n\n---\n\n")

    -- Ensure directory exists
    local util = require("util")
    local dir = notebook_path:match("(.*/)") or ""
    if dir ~= "" then
        util.makePath(dir)
    end

    local file, err = io.open(notebook_path, "w")
    if not file then
        logger.err("KOAssistant Notebook: Failed to create file:", err)
        return false, "Failed to create: " .. (err or "unknown")
    end

    file:write(table.concat(content_parts, ""))
    file:close()

    -- Store DocSettings ref for vault mode (travels with book on move)
    if location ~= "sidecar" and final_filename then
        doc_settings:saveSetting("koassistant_notebook_ref", {
            filename = final_filename,
            created = os.time(),
        })
        doc_settings:flush()
    end

    return true, nil
end

return Notebook
