--- DOI (Digital Object Identifier) extraction and resolution.
--- Extracts DOIs from document metadata, page text, and doc_settings cache.
--- Used by buildBookMetadata() to enable research mode features.

local DOIResolver = {}

--- Match a DOI pattern in text.
--- @param text string|nil Text to search
--- @return string|nil The matched DOI, or nil
function DOIResolver.matchDOI(text)
    if not text or text == "" then return nil end
    local doi = text:match("10%.%d%d%d%d%d?%d?%d?%d?%d?/[^%s,;\"'%)%]>]+")
    if doi then
        -- Strip trailing punctuation that's likely not part of the DOI
        doi = doi:gsub("[%.%)%]};,]+$", "")
        return doi
    end
    return nil
end

--- Extract DOI from document properties.
--- Checks identifiers (EPUB), description (PDF), and keywords fields.
--- @param doc_props table|nil Document properties table
--- @return string|nil The extracted DOI, or nil
function DOIResolver.extractDOI(doc_props)
    if not doc_props then return nil end
    return DOIResolver.matchDOI(doc_props.identifiers)
        or DOIResolver.matchDOI(doc_props.description)
        or DOIResolver.matchDOI(doc_props.keywords)
end

--- Extract DOI from the first page of a document's body text.
--- Text is extracted locally and discarded — only the DOI string is returned.
--- Works for PDFs (page-based) where publishers print DOI on page 1.
--- @param document table KOReader document object
--- @return string|nil The extracted DOI, or nil
function DOIResolver.extractDOIFromPage(document)
    local ok, page_text = pcall(function()
        return document:getPageText(1)
    end)
    if not ok or not page_text then return nil end
    -- Handle table return type (PDF structured text: blocks → spans → words)
    if type(page_text) == "table" then
        local words = {}
        for _, block in ipairs(page_text) do
            if type(block) == "table" then
                for i = 1, #block do
                    local span = block[i]
                    if type(span) == "table" and span.word then
                        table.insert(words, span.word)
                    end
                end
            end
        end
        page_text = table.concat(words, " ")
    end
    if type(page_text) ~= "string" or page_text == "" then return nil end
    return DOIResolver.matchDOI(page_text)
end

--- Resolve DOI for a document using all available sources.
--- Check order: doc_settings cache → metadata fields → first-page text scan.
--- Caches result in doc_settings to avoid re-scanning.
--- @param file string|nil Document file path (for caching via standalone DocSettings)
--- @param doc_props table|nil Document properties (raw preferred)
--- @param document table|nil KOReader document object (for text scan; nil when book not open)
--- @param live_doc_settings table|nil Shared KOReader doc_settings (use when book is open to
---   avoid race with KOReader's own save; nil triggers standalone DocSettings:open)
--- @return string|nil The resolved DOI, or nil
function DOIResolver.resolveDOI(file, doc_props, document, live_doc_settings)
    -- Get or open doc_settings for cache read/write
    -- When book is open: use shared live_doc_settings (persists with KOReader's save)
    -- When book not open: open standalone instance (safe since KOReader isn't using it)
    local settings = live_doc_settings
    if not settings and file then
        local DocSettings = require("docsettings")
        local ok, ds = pcall(DocSettings.open, DocSettings, file)
        if ok then settings = ds end
    end

    -- 1. Check doc_settings cache (instant, avoids re-scanning)
    if settings and settings:has("koassistant_doi") then
        local cached = settings:readSetting("koassistant_doi")
        -- false sentinel = "scanned, no DOI found"
        return cached or nil
    end

    -- 2. Try metadata extraction (identifiers → description → keywords)
    local doi = DOIResolver.extractDOI(doc_props)
    if doi then
        if settings then
            settings:saveSetting("koassistant_doi", doi)
            -- Only flush standalone instances; live_doc_settings persists with KOReader's save
            if not live_doc_settings then settings:flush() end
        end
        return doi
    end

    -- 3. Try first-page text scan (only when document is open)
    if document then
        doi = DOIResolver.extractDOIFromPage(document)
        -- Cache result: DOI string or false sentinel (scanned, not found)
        if settings then
            settings:saveSetting("koassistant_doi", doi or false)
            if not live_doc_settings then settings:flush() end
        end
        return doi
    end

    -- No document access (file browser) and no metadata DOI — don't cache false
    -- (a future open-book action might find it via text scan)
    return nil
end

--- Build standardized book metadata table for template substitution.
--- Resolves DOI from cache, metadata, or first-page text scan.
--- @param title string Book title
--- @param authors string Author name(s)
--- @param file string|nil File path for chat saving
--- @param doc_props table|nil Document properties (raw preferred, for identifiers)
--- @param document table|nil KOReader document object (for first-page DOI scan)
--- @param doc_settings table|nil Shared KOReader doc_settings (for persistent DOI caching)
--- @return table Book metadata with title, author, author_clause, file, doi, doi_clause
function DOIResolver.buildBookMetadata(title, authors, file, doc_props, document, doc_settings)
    authors = authors or ""
    local doi = DOIResolver.resolveDOI(file, doc_props, document, doc_settings)
    return {
        title = title or "Unknown",
        author = authors,
        author_clause = authors ~= "" and (" by " .. authors) or "",
        file = file,
        doi = doi,
        doi_clause = doi and ("\nDOI: " .. doi) or "",
    }
end

return DOIResolver
