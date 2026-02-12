--[[--
X-Ray Browser for KOAssistant

Browsable menu UI for structured X-Ray data.
Presents categories (Cast, World, Ideas, etc.) with item counts,
drill-down into category items, detail views, chapter character tracking,
and search.

Uses a single Menu instance with switchItemTable() for navigation,
maintaining a stack for back-arrow support.

@module koassistant_xray_browser
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local Screen = Device.screen
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local _ = require("koassistant_gettext")
local T = require("ffi/util").template

local Constants = require("koassistant_constants")
local XrayParser = require("koassistant_xray_parser")

local XrayBrowser = {}

--- Get current page number from KOReader UI
--- @param ui table KOReader UI instance
--- @return number current_page
local function getCurrentPage(ui)
    if ui.document.info.has_pages then
        -- PDF/DJVU
        return ui.view and ui.view.state and ui.view.state.page or 1
    else
        -- EPUB/reflowable
        local xp = ui.document:getXPointer()
        return xp and ui.document:getPageFromXPointer(xp) or 1
    end
end

--- Get chapter boundaries from KOReader's TOC
--- @param ui table KOReader UI instance
--- @param target_depth number|nil TOC depth filter (nil = deepest match)
--- @return table|nil chapter {title, start_page, end_page, depth}
--- @return table toc_info {max_depth, has_toc, entry_count, depth_counts}
local function getChapterBoundaries(ui, target_depth)
    local toc = ui.toc and ui.toc.toc
    if not toc or #toc == 0 then
        return nil, { has_toc = false, max_depth = 0, entry_count = 0 }
    end

    -- Filter out TOC entries from hidden flows
    local effective_toc = toc
    if ui.document.hasHiddenFlows and ui.document:hasHiddenFlows() then
        effective_toc = {}
        for _idx, entry in ipairs(toc) do
            if entry.page and ui.document:getPageFlow(entry.page) == 0 then
                table.insert(effective_toc, entry)
            end
        end
        if #effective_toc == 0 then
            return nil, { has_toc = false, max_depth = 0, entry_count = 0 }
        end
    end

    local total_pages = ui.document.info.number_of_pages or 0
    local current_page = getCurrentPage(ui)

    -- First pass: collect depth stats and current entry at each depth
    local max_depth = 0
    local depth_counts = {}
    local depth_titles = {}  -- current entry title at each depth level
    for _idx, entry in ipairs(effective_toc) do
        local d = entry.depth or 1
        if d > max_depth then max_depth = d end
        depth_counts[d] = (depth_counts[d] or 0) + 1
        -- Track the last entry at each depth that's before current page
        if entry.page and entry.page <= current_page then
            depth_titles[d] = entry.title or ""
        end
    end

    local toc_info = {
        has_toc = true,
        max_depth = max_depth,
        entry_count = #effective_toc,
        depth_counts = depth_counts,
        depth_titles = depth_titles,
    }

    -- Filter entries to target_depth (or use all if nil)
    local filtered = {}
    for _idx, entry in ipairs(effective_toc) do
        local d = entry.depth or 1
        if not target_depth or d == target_depth then
            table.insert(filtered, entry)
        end
    end

    if #filtered == 0 then return nil, toc_info end

    -- Find last filtered entry where entry.page <= current_page
    local match_idx
    for i, entry in ipairs(filtered) do
        if entry.page and entry.page <= current_page then
            match_idx = i
        end
    end

    if not match_idx then return nil, toc_info end

    local matched = filtered[match_idx]
    local end_page
    if filtered[match_idx + 1] and filtered[match_idx + 1].page then
        end_page = filtered[match_idx + 1].page - 1
    else
        end_page = total_pages
    end

    return {
        title = matched.title or "",
        start_page = matched.page,
        end_page = end_page,
        depth = matched.depth or 1,
    }, toc_info
end

--- Get ALL chapter boundaries from TOC at a given depth
--- Unlike getChapterBoundaries() which returns only the current chapter,
--- this returns every chapter for use in distribution views.
--- @param ui table KOReader UI instance
--- @param target_depth number|nil TOC depth filter (nil = deepest)
--- @return table|nil chapters Array of {title, start_page, end_page, depth, is_current}
--- @return table toc_info {max_depth, has_toc, depth_counts, depth_titles}
local function getAllChapterBoundaries(ui, target_depth, coverage_page)
    local toc = ui.toc and ui.toc.toc
    if not toc or #toc == 0 then
        return nil, { has_toc = false, max_depth = 0, entry_count = 0 }
    end

    -- Filter out TOC entries from hidden flows
    local effective_toc = toc
    if ui.document.hasHiddenFlows and ui.document:hasHiddenFlows() then
        effective_toc = {}
        for _idx, entry in ipairs(toc) do
            if entry.page and ui.document:getPageFlow(entry.page) == 0 then
                table.insert(effective_toc, entry)
            end
        end
        if #effective_toc == 0 then
            return nil, { has_toc = false, max_depth = 0, entry_count = 0 }
        end
    end

    local total_pages = ui.document.info.number_of_pages or 0
    local current_page = getCurrentPage(ui)
    -- Spoiler gate: max of X-Ray coverage and reading position
    -- Chapters beyond this are marked unread (dimmed + spoiler warning)
    local gate_page = math.max(coverage_page or current_page, current_page)

    -- First pass: collect depth stats
    local max_depth = 0
    local depth_counts = {}
    local depth_titles = {}
    for _idx, entry in ipairs(effective_toc) do
        local d = entry.depth or 1
        if d > max_depth then max_depth = d end
        depth_counts[d] = (depth_counts[d] or 0) + 1
        if entry.page and entry.page <= current_page then
            depth_titles[d] = entry.title or ""
        end
    end

    local toc_info = {
        has_toc = true,
        max_depth = max_depth,
        entry_count = #effective_toc,
        depth_counts = depth_counts,
        depth_titles = depth_titles,
    }

    -- Use deepest depth if not specified
    local depth = target_depth or max_depth

    -- Filter entries to target depth, but include shallower entries
    -- that have no children at the target depth (e.g., "Introduction" at depth 1
    -- when other parts have sub-chapters at depth 3)
    local filtered = {}
    for i, entry in ipairs(effective_toc) do
        local d = entry.depth or 1
        if d == depth then
            table.insert(filtered, entry)
        elseif d < depth then
            -- Check if this entry has any descendants at the target depth
            local has_children_at_depth = false
            for j = i + 1, #effective_toc do
                local child_depth = effective_toc[j].depth or 1
                if child_depth <= d then break end  -- Past this entry's subtree
                if child_depth == depth then
                    has_children_at_depth = true
                    break
                end
            end
            if not has_children_at_depth then
                table.insert(filtered, entry)
            end
        end
    end

    if #filtered == 0 then return nil, toc_info end

    -- Build chapter array with boundaries
    -- Chapters past reading position are included but marked unread (for grayed-out display)
    local chapters = {}
    for i, entry in ipairs(filtered) do
        if not entry.page then goto continue end

        local end_page
        if filtered[i + 1] and filtered[i + 1].page then
            end_page = filtered[i + 1].page - 1
        else
            end_page = total_pages
        end
        local is_unread = entry.page > gate_page
        local is_current = not is_unread and current_page <= end_page
        table.insert(chapters, {
            title = entry.title or "",
            start_page = entry.page,
            end_page = end_page,
            depth = entry.depth or 1,
            is_current = is_current or false,
            unread = is_unread,
        })
        ::continue::
    end

    return chapters, toc_info
end

--- Get ALL page-range chunks for books without usable TOC
--- Chunks past current reading position are marked unread
--- @param ui table KOReader UI instance
--- @return table chapters Array of {title, start_page, end_page, depth, is_current, unread}
--- @return table toc_info {has_toc = false, max_depth = 0}
local function getAllPageRangeChapters(ui, coverage_page)
    local total_pages = ui.document.info.number_of_pages or 0
    local current_page = getCurrentPage(ui)
    local gate_page = math.max(coverage_page or current_page, current_page)
    local chunk = math.max(20, math.floor(total_pages * 0.05))
    local chapters = {}
    local start = 1
    while start <= total_pages do
        local end_page = math.min(start + chunk - 1, total_pages)
        local is_unread = start > gate_page
        local is_current = not is_unread and current_page >= start and current_page <= end_page
        table.insert(chapters, {
            title = T(_("Pages %1–%2"), start, end_page),
            start_page = start,
            end_page = end_page,
            depth = 0,
            is_current = is_current,
            unread = is_unread,
        })
        start = end_page + 1
    end
    return chapters, { has_toc = false, max_depth = 0 }
end

--- Get ALL TOC entries hierarchically (all depths) with page ranges and spoiler gating.
--- Unlike getAllChapterBoundaries() which filters to one depth, this returns every entry
--- for use in a KOReader-style hierarchical TOC with expand/collapse.
--- @param ui table KOReader UI instance
--- @param coverage_page number|nil X-Ray coverage page
--- @return table|nil entries Array of {title, start_page, end_page, depth, is_current, unread}
--- @return number max_depth Maximum TOC depth found
local function getHierarchicalChapters(ui, coverage_page)
    local toc = ui.toc and ui.toc.toc
    if not toc or #toc == 0 then return nil, 0 end

    -- Filter out TOC entries from hidden flows
    local effective_toc = toc
    if ui.document.hasHiddenFlows and ui.document:hasHiddenFlows() then
        effective_toc = {}
        for _idx, entry in ipairs(toc) do
            if entry.page and ui.document:getPageFlow(entry.page) == 0 then
                table.insert(effective_toc, entry)
            end
        end
        if #effective_toc == 0 then return nil, 0 end
    end

    local total_pages = ui.document.info.number_of_pages or 0
    local current_page = getCurrentPage(ui)
    local gate_page = math.max(coverage_page or current_page, current_page)

    local max_depth = 0
    for _idx, entry in ipairs(effective_toc) do
        local d = entry.depth or 1
        if d > max_depth then max_depth = d end
    end

    -- Build entries with end_page scoped to same-or-shallower next sibling
    local entries = {}
    for i, entry in ipairs(effective_toc) do
        if not entry.page then goto continue end
        local d = entry.depth or 1
        -- end_page = page before next entry at same or shallower depth
        local end_page = total_pages
        for j = i + 1, #effective_toc do
            local next_d = effective_toc[j].depth or 1
            if next_d <= d and effective_toc[j].page then
                end_page = effective_toc[j].page - 1
                break
            end
        end
        local is_unread = entry.page > gate_page
        local is_current = not is_unread and current_page >= entry.page and current_page <= end_page
        table.insert(entries, {
            title = entry.title or "",
            start_page = entry.page,
            end_page = end_page,
            depth = d,
            is_current = is_current,
            unread = is_unread,
        })
        ::continue::
    end

    return entries, max_depth
end

--- Get page-range chapter for books without usable TOC
--- @param ui table KOReader UI instance
--- @return table chapter {title, start_page, end_page, depth}
--- @return table toc_info {has_toc = false, max_depth = 0}
local function getPageRangeChapter(ui)
    local total_pages = ui.document.info.number_of_pages or 0
    local current_page = getCurrentPage(ui)
    local chunk = math.max(20, math.floor(total_pages * 0.05))
    local start_page = math.floor((current_page - 1) / chunk) * chunk + 1
    local end_page = math.min(start_page + chunk - 1, total_pages)
    return {
        title = T(_("Pages %1–%2"), start_page, end_page),
        start_page = start_page,
        end_page = end_page,
        depth = 0,
    }, { has_toc = false, max_depth = 0 }
end

--- Extract text from visible page ranges using XPointers (browser-local helper).
--- @param document table KOReader document object
--- @param ranges table Array of {start_page, end_page}
--- @param total_pages number Total pages in document
--- @return string text
local function extractVisibleText(document, ranges, total_pages)
    if #ranges == 0 then return "" end
    local parts = {}
    for _idx, r in ipairs(ranges) do
        local start_xp = document:getPageXPointer(r.start_page)
        local end_xp = document:getPageXPointer(math.min(r.end_page + 1, total_pages))
        if start_xp and end_xp then
            local text = document:getTextFromXPointers(start_xp, end_xp)
            if text and text ~= "" then
                table.insert(parts, text)
            end
        end
    end
    return table.concat(parts, "\n")
end

--- Extract text between page boundaries
--- @param ui table KOReader UI instance
--- @param chapter table {start_page, end_page}
--- @param max_chars number Optional cap (default 5000000)
--- @return string text
local function extractChapterText(ui, chapter, max_chars)
    max_chars = max_chars or 5000000
    local text = ""

    if ui.document.info.has_pages then
        -- PDF: iterate pages
        local document = ui.document
        local has_hidden = document.hasHiddenFlows and document:hasHiddenFlows()
        local parts = {}
        local char_count = 0
        local end_page = math.min(chapter.end_page, chapter.start_page + 50)  -- Cap pages too
        for page = chapter.start_page, end_page do
            -- Skip hidden flow pages
            if has_hidden and document:getPageFlow(page) ~= 0 then
                -- skip
            else
            local ok, page_text = pcall(document.getPageText, document, page)
            if ok and page_text then
                -- getPageText returns a table of text blocks for PDFs
                if type(page_text) == "table" then
                    for _idx, block in ipairs(page_text) do
                        if block.text then
                            table.insert(parts, block.text)
                            char_count = char_count + #block.text
                        elseif type(block) == "table" then
                            -- Nested format from MuPDF: { {word="..."}, ... }
                            for i = 1, #block do
                                local span = block[i]
                                if type(span) == "table" and span.word then
                                    table.insert(parts, span.word)
                                    char_count = char_count + #span.word
                                end
                            end
                        end
                    end
                elseif type(page_text) == "string" then
                    table.insert(parts, page_text)
                    char_count = char_count + #page_text
                end
                if char_count >= max_chars then break end
            end
            end -- if has_hidden skip/else
        end
        text = table.concat(parts, " ")
    else
        -- EPUB/reflowable: use xpointers for page range
        local document = ui.document
        local total_pages = document.info.number_of_pages or 0
        local ok, result = pcall(function()
            if document.hasHiddenFlows and document:hasHiddenFlows() then
                -- Flow-aware: extract only visible pages within chapter range
                local ContextExtractor = require("koassistant_context_extractor")
                local ranges = ContextExtractor.getVisiblePageRanges(document,
                    chapter.start_page, math.min(chapter.end_page, total_pages))
                return extractVisibleText(document, ranges, total_pages)
            else
                local start_xp = document:getPageXPointer(chapter.start_page)
                local end_xp = document:getPageXPointer(math.min(chapter.end_page + 1, total_pages))
                if start_xp and end_xp then
                    return document:getTextFromXPointers(start_xp, end_xp)
                end
            end
        end)
        if ok and result then
            text = result
        end
    end

    -- Cap length
    if #text > max_chars then
        text = text:sub(1, max_chars)
    end

    return text
end

--- Extract text for the current chapter from the open document
--- @param ui table KOReader UI instance
--- @param target_depth number|nil TOC depth filter (nil = deepest match)
--- @param browser table|nil XrayBrowser instance (uses _text_cache when provided)
--- @return string chapter_text The extracted text, or empty string
--- @return string chapter_title The chapter title, or empty string
--- @return table|nil toc_info TOC metadata for depth selector
local function getCurrentChapterText(ui, target_depth, browser)
    if not ui or not ui.document then return "", "", nil end

    local total_pages = ui.document.info and ui.document.info.number_of_pages or 0
    if total_pages == 0 then return "", "", nil end

    local chapter, toc_info = getChapterBoundaries(ui, target_depth)
    if not chapter then
        chapter, toc_info = getPageRangeChapter(ui)
    end
    if not chapter then return "", "", nil end

    local text
    if browser then
        text = browser:_getChapterText(chapter)
    else
        text = extractChapterText(ui, chapter)
    end
    return text, chapter.title or "", toc_info
end

--- Find user highlights that mention an X-Ray item (by name, term, event, or aliases)
--- @param item table X-Ray item entry
--- @param ui table KOReader UI instance
--- @return table matches Array of highlight text strings
local function findItemHighlights(item, ui)
    if not ui or not ui.annotation or not ui.annotation.annotations then
        return {}
    end

    -- Build list of names to search for
    local names = {}
    local primary_name = item.name or item.term or item.event
    if primary_name and #primary_name > 2 then
        table.insert(names, primary_name:lower())
    end
    if type(item.aliases) == "table" then
        for _idx, alias in ipairs(item.aliases) do
            if #alias > 2 then
                table.insert(names, alias:lower())
            end
        end
    end
    if #names == 0 then return {} end

    local matches = {}
    for _idx, annotation in ipairs(ui.annotation.annotations) do
        local ann_text = annotation.text
        if ann_text and ann_text ~= "" then
            local text_lower = ann_text:lower()
            for _idx2, name in ipairs(names) do
                if text_lower:find(name, 1, true) then
                    table.insert(matches, ann_text)
                    break
                end
            end
        end
    end
    return matches
end

--- Text selection handler matching ChatGPTViewer behavior:
--- ≤3 words → dictionary lookup, 4+ words → clipboard copy
--- @param text string Selected text
--- @param ui table|nil KOReader UI instance
local function handleTextSelection(text, ui)
    -- Count words
    local word_count = 0
    if text then
        for _w in text:gmatch("%S+") do
            word_count = word_count + 1
            if word_count > 3 then break end
        end
    end

    local did_lookup = false
    if word_count >= 1 and word_count <= 3 then
        if ui and ui.dictionary then
            ui.dictionary:onLookupWord(text)
            did_lookup = true
        end
    end

    if not did_lookup then
        if Device:hasClipboard() then
            Device.input.setClipboardText(text)
            UIManager:show(Notification:new{
                text = _("Copied to clipboard."),
            })
        end
    end
end

-- Emoji mappings for category keys (used when enable_emoji_icons is on)
local CATEGORY_EMOJIS = {
    characters = "👥", key_figures = "👥",
    locations = "🌍", core_concepts = "💡",
    themes = "💭", arguments = "⚖️",
    lexicon = "📖", terminology = "📖",
    timeline = "📅", argument_development = "📅",
    reader_engagement = "📌",
    current_state = "📍", current_position = "📍",
    conclusion = "🏁",
}

-- Categories excluded from per-item distribution and highlight matching
-- Matches TEXT_MATCH_EXCLUDED in parser: singletons + event-based categories
-- whose "names" are descriptive phrases, not searchable entity names
local DISTRIBUTION_EXCLUDED = {
    current_state = true,
    current_position = true,
    reader_engagement = true,
    arguments = true,
    argument_development = true,
    timeline = true,
}

--- Show the top-level X-Ray category menu
--- @param xray_data table Parsed JSON structure
--- @param metadata table { title, progress, model, timestamp, book_file, enable_emoji }
--- @param ui table|nil KOReader UI instance (nil when book not open)
--- @param on_delete function|nil Callback to delete this cache
function XrayBrowser:show(xray_data, metadata, ui, on_delete)
    self.xray_data = xray_data
    self.metadata = metadata
    self.ui = ui
    self.on_delete = on_delete
    self.nav_stack = {}
    self._mentions_spoiler_warned = nil

    -- Compute X-Ray coverage page for spoiler gating
    -- Text-matching features (Mentions, Chapter Appearances) gate to max(coverage, reading),
    -- so chapters the reader has physically read OR the X-Ray has analyzed are never spoiler-gated.
    self.coverage_page = nil
    self.is_complete = false
    if ui and ui.document then
        local total_pages = ui.document.info and ui.document.info.number_of_pages
        if total_pages and total_pages > 0 then
            if metadata.full_document then
                self.coverage_page = total_pages
            elseif metadata.progress_decimal then
                self.coverage_page = math.floor(metadata.progress_decimal * total_pages + 0.5)
                if self.coverage_page > total_pages then self.coverage_page = total_pages end
            end
        end
    end
    self.is_complete = metadata.full_document == true
        or (metadata.progress_decimal and metadata.progress_decimal >= 0.995) or false

    -- Build update callback from plugin reference (works from all call sites)
    self.on_update = nil
    self.on_update_full = nil
    if metadata.plugin and ui and ui.document then
        local plugin_ref = metadata.plugin
        self.on_update = function()
            local action = plugin_ref.action_service:getAction("book", "xray")
            if action then
                plugin_ref:_executeBookLevelActionDirect(action, "xray")
            end
        end
        self.on_update_full = function()
            local action = plugin_ref.action_service:getAction("book", "xray")
            if action then
                plugin_ref:_executeBookLevelActionDirect(action, "xray", { full_document = true })
            end
        end
        self.on_update_to_100 = function()
            local action = plugin_ref.action_service:getAction("book", "xray")
            if action then
                plugin_ref:_executeBookLevelActionDirect(action, "xray", { update_to_full = true })
            end
        end
    end

    -- Merge user-defined search terms into item aliases
    if metadata.book_file then
        local ActionCache = require("koassistant_action_cache")
        local user_aliases = ActionCache.getUserAliases(metadata.book_file)
        if next(user_aliases) then
            XrayParser.mergeUserAliases(self.xray_data, user_aliases)
        end
    end

    local items = self:buildCategoryItems()
    local title = self:buildMainTitle()
    self.current_title = title

    local self_ref = self
    self.menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        single_line = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function()
            self_ref:showOptions()
        end,
        onReturn = function()
            self_ref:navigateBack()
        end,
        -- NOTE: Do NOT use close_callback here. KOReader's Menu:onMenuSelect()
        -- calls close_callback after every item tap, not just on widget close.
        -- Cleanup is done via onCloseWidget instead.
    }
    -- Hook into onCloseWidget for cleanup (only fires when widget is actually removed)
    local orig_onCloseWidget = self.menu.onCloseWidget
    self.menu.onCloseWidget = function(menu_self)
        self_ref.menu = nil
        self_ref.nav_stack = {}
        self_ref._dist_cache = nil
        self_ref._text_cache = nil
        self_ref.on_update = nil
        if orig_onCloseWidget then
            return orig_onCloseWidget(menu_self)
        end
    end
    UIManager:show(self.menu)
end

--- Get chapter text with per-session caching (raw + lowered).
--- First call extracts via extractChapterText(); subsequent calls return cached.
--- @param chapter table {start_page, end_page}
--- @return string raw Raw extracted text
--- @return string lower Lowercased text (for countItemOccurrences)
function XrayBrowser:_getChapterText(chapter)
    self._text_cache = self._text_cache or {}
    local key = chapter.start_page .. ":" .. chapter.end_page
    local cached = self._text_cache[key]
    if cached then
        return cached.raw, cached.lower
    end
    local raw = extractChapterText(self.ui, chapter)
    local lower = raw ~= "" and raw:lower() or ""
    self._text_cache[key] = { raw = raw, lower = lower }
    return raw, lower
end

--- Build the main title for the browser
--- @return string title
function XrayBrowser:buildMainTitle()
    local title = "X-Ray"
    if self.metadata.progress then
        title = title .. " (" .. self.metadata.progress .. ")"
    end
    return title
end

--- Build item table for the top-level category menu
--- @return table items Menu item table
function XrayBrowser:buildCategoryItems()
    local categories = XrayParser.getCategories(self.xray_data)
    local enable_emoji = self.metadata.enable_emoji
    local self_ref = self

    local items = {}

    -- Category items with counts
    for _idx, cat in ipairs(categories) do
        local count = #cat.items
        if count > 0 then
            local mandatory_text = ""
            -- Don't show count for current_state/current_position (always 1)
            if cat.key ~= "current_state" and cat.key ~= "current_position"
                and cat.key ~= "reader_engagement" then
                mandatory_text = tostring(count)
            end

            local label = Constants.getEmojiText(CATEGORY_EMOJIS[cat.key] or "", cat.label, enable_emoji)
            local captured_cat = cat
            table.insert(items, {
                text = label,
                mandatory = mandatory_text,
                callback = function()
                    if captured_cat.key == "current_state" or captured_cat.key == "current_position"
                        or captured_cat.key == "reader_engagement" or captured_cat.key == "conclusion" then
                        self_ref:showItemDetail(captured_cat.items[1], captured_cat.key, captured_cat.label)
                    else
                        self_ref:showCategoryItems(captured_cat)
                    end
                end,
            })
        end
    end

    -- Separator before utility items
    if #items > 0 then
        items[#items].separator = true
    end

    -- Mentions: unified chapter-navigable text matching
    table.insert(items, {
        text = Constants.getEmojiText("📑", _("Mentions"), enable_emoji),
        callback = function()
            if self_ref.ui and self_ref.ui.document then
                self_ref:showMentions()
            else
                self_ref:_showReaderRequired()
            end
        end,
    })

    -- Search
    table.insert(items, {
        text = Constants.getEmojiText("🔍", _("Search"), enable_emoji),
        callback = function()
            self_ref:showSearch()
        end,
    })

    -- Full View
    table.insert(items, {
        text = Constants.getEmojiText("📄", _("Full View"), enable_emoji),
        callback = function()
            self_ref:showFullView()
        end,
    })

    return items
end

--- Navigate forward: push current state and switch to new items
--- @param title string New menu title
--- @param items table New menu items
function XrayBrowser:navigateForward(title, items)
    if not self.menu then return end

    -- Save current state
    table.insert(self.nav_stack, {
        title = self.current_title,
        items = self.menu.item_table,
    })
    self.current_title = title

    -- Add to paths so back arrow becomes enabled via updatePageInfo
    table.insert(self.menu.paths, true)
    self.menu:switchItemTable(title, items)
end

--- Navigate back: pop state and restore, or close if at root
function XrayBrowser:navigateBack()
    if not self.menu then return end

    if #self.nav_stack == 0 then
        -- At root level — close the browser
        UIManager:close(self.menu)
        return
    end

    local prev = table.remove(self.nav_stack)
    self.current_title = prev.title

    -- Remove from paths so back arrow disables when we reach root
    table.remove(self.menu.paths)
    self.menu:switchItemTable(prev.title, prev.items)
end

--- Show items within a category (navigates forward)
--- @param category table {key, label, items}
function XrayBrowser:showCategoryItems(category)
    local Font = require("ui/font")
    local Size = require("ui/size")
    local TextWidget = require("ui/widget/textwidget")

    local items = {}
    local self_ref = self

    -- Measure available width and font metrics for dynamic mandatory truncation.
    -- Menu uses: available_width = content_width - mandatory_w - padding
    -- We flip the priority: give name its full width, truncate mandatory to fit the rest.
    local content_width = Screen:getWidth() - 2 * (Size.padding.fullscreen or 0)
    local text_face = Font:getFace("smallinfofont", 18)
    local mandatory_face = Font:getFace("infont", 14)
    -- Measure a reference character to estimate mandatory chars per pixel
    local ref_char_w = TextWidget:new{ text = "a", face = mandatory_face }:getSize().w
    local padding = Screen:scaleBySize(10)

    for _idx, item in ipairs(category.items) do
        local name = XrayParser.getItemName(item, category.key)
        local secondary = XrayParser.getItemSecondary(item, category.key)

        -- Measure actual name width in pixels, then truncate mandatory to fit remainder
        if secondary ~= "" then
            local name_w = TextWidget:new{ text = name, face = text_face }:getSize().w
            local avail_for_mandatory = content_width - name_w - padding
            local max_chars = math.max(5, math.floor(avail_for_mandatory / ref_char_w))
            if #secondary > max_chars then
                secondary = secondary:sub(1, max_chars - 3) .. "..."
            end
        end

        local captured_item = item
        table.insert(items, {
            text = name,
            mandatory = secondary,
            mandatory_dim = true,
            callback = function()
                self_ref:showItemDetail(captured_item, category.key, name)
            end,
        })
    end

    local title = category.label .. " (" .. #category.items .. ")"
    self:navigateForward(title, items)
end

--- Show detail view for a single item (overlays as TextViewer)
--- @param item table The item data
--- @param category_key string The category key
--- @param title string Display title
function XrayBrowser:showItemDetail(item, category_key, title, source)
    local detail_text = XrayParser.formatItemDetail(item, category_key)

    -- For current state/position: prepend reading progress for clarity
    if (category_key == "current_state" or category_key == "current_position") and self.metadata.progress then
        detail_text = _("As of") .. " " .. self.metadata.progress .. "\n\n" .. detail_text
    end

    -- Append matching highlights for searchable categories
    if not DISTRIBUTION_EXCLUDED[category_key] and self.ui then
        local config_features = (self.metadata.configuration or {}).features or {}
        -- Check trusted provider (bypasses privacy settings)
        local provider = config_features.provider
        local provider_trusted = false
        if provider then
            for _idx, trusted_id in ipairs(config_features.trusted_providers or {}) do
                if trusted_id == provider then
                    provider_trusted = true
                    break
                end
            end
        end
        local highlights_allowed = provider_trusted
            or config_features.enable_highlights_sharing == true
            or config_features.enable_annotations_sharing == true
        local highlights = highlights_allowed and findItemHighlights(item, self.ui) or {}
        if #highlights > 0 then
            detail_text = detail_text .. "\n\n" .. _("Your highlights:") .. "\n"
            for _idx, hl in ipairs(highlights) do
                -- Truncate very long highlights
                local display_hl = hl
                if #display_hl > 200 then
                    display_hl = display_hl:sub(1, 200) .. "..."
                end
                detail_text = detail_text .. "\n> " .. display_hl
            end
        end
    end

    local captured_ui = self.ui
    local self_ref = self

    -- Build custom button row: ← ⇱ ⇲ [Chat about this]
    local row = {}
    local viewer  -- forward declaration for button callbacks

    table.insert(row, {
        text = "←",
        callback = function()
            if viewer then viewer:onClose() end
            if source then
                self_ref:showItemDetail(source.item, source.category_key,
                    source.title, source.source)
            end
        end,
    })
    table.insert(row, {
        text = "⇱",
        id = "top",
        callback = function()
            if viewer then viewer.scroll_text_w:scrollToTop() end
        end,
    })
    table.insert(row, {
        text = "⇲",
        id = "bottom",
        callback = function()
            if viewer then viewer.scroll_text_w:scrollToBottom() end
        end,
    })
    if self.metadata.plugin and self.metadata.configuration then
        table.insert(row, {
            text = _("Chat about this"),
            callback = function()
                if viewer then viewer:onClose() end
                self_ref:chatAboutItem(detail_text)
            end,
        })
    end

    local buttons_rows = {}

    -- "Chapter Appearances" + "Add Search Term" row (searchable categories)
    if not DISTRIBUTION_EXCLUDED[category_key] then
        local search_row = {}
        local dist_item_name = XrayParser.getItemName(item, category_key)
        table.insert(search_row, {
            text = _("Chapter Appearances"),
            callback = function()
                if self_ref.ui and self_ref.ui.document then
                    if viewer then viewer:onClose() end
                    self_ref:showItemDistribution(item, category_key, dist_item_name)
                else
                    self_ref:_showReaderRequired()
                end
            end,
        })
        if self.metadata.book_file then
            table.insert(search_row, {
                text = _("Edit Search Terms"),
                callback = function()
                    if viewer then viewer:onClose() end
                    self_ref:editSearchTerms(item, category_key, title, source)
                end,
            })
        end
        if #search_row > 0 then
            table.insert(buttons_rows, search_row)
        end
    end

    -- Resolve references into tappable cross-category navigation buttons
    if self.xray_data then
        -- Characters/key_figures: resolve connections (other characters/items)
        -- Other categories: resolve references or characters field
        local names_list
        if category_key == "characters" or category_key == "key_figures" then
            names_list = item.connections
        else
            names_list = item.references or item.characters
        end
        if type(names_list) == "string" and names_list ~= "" then
            names_list = { names_list }
        end
        if type(names_list) == "table" and #names_list > 0 then
            local current_source = {
                item = item,
                category_key = category_key,
                title = title,
                source = source,  -- Preserve chain for deep back-navigation
            }
            local conn_row = {}
            for _idx, name_str in ipairs(names_list) do
                local resolved = XrayParser.resolveConnection(self.xray_data, name_str)
                if resolved and resolved.item ~= item then  -- Skip self-references
                    local captured_resolved = resolved
                    local resolved_name = captured_resolved.item.name
                        or captured_resolved.item.term
                        or captured_resolved.item.event
                        or _("Details")
                    table.insert(conn_row, {
                        text = captured_resolved.name_portion,
                        callback = function()
                            if viewer then viewer:onClose() end
                            self_ref:showItemDetail(captured_resolved.item,
                                captured_resolved.category_key,
                                resolved_name, current_source)
                        end,
                    })
                    -- Start a new row every 3 buttons
                    if #conn_row == 3 then
                        table.insert(buttons_rows, conn_row)
                        conn_row = {}
                    end
                end
            end
            if #conn_row > 0 then
                table.insert(buttons_rows, conn_row)
            end
        end
    end

    -- Navigation bar (last row — arrows + chat)
    table.insert(buttons_rows, row)

    viewer = TextViewer:new{
        title = title or _("Details"),
        text = detail_text,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        buttons_table = buttons_rows,
        text_selection_callback = function(text)
            handleTextSelection(text, captured_ui)
        end,
    }
    -- Enable gray highlight on text selection (TextViewer doesn't expose this prop)
    if viewer.scroll_text_w and viewer.scroll_text_w.text_widget then
        viewer.scroll_text_w.text_widget.highlight_text_selection = true
    end
    -- Fix live highlight during drag: TextViewer uses ges="hold" for HoldPanText
    -- (fires once) instead of ges="hold_pan" (fires continuously during drag)
    if viewer.ges_events and viewer.ges_events.HoldPanText
            and viewer.ges_events.HoldPanText[1] then
        viewer.ges_events.HoldPanText[1].ges = "hold_pan"
        viewer.ges_events.HoldPanText[1].rate = Screen.low_pan_rate and 5.0 or 30.0
    end
    UIManager:show(viewer)
end

--- Show dialog to add a custom search term for an item
--- Unified edit dialog for search terms: add, remove user terms, ignore/restore AI terms
--- @param item table The item data
--- @param category_key string The category key
--- @param item_title string Display title for refreshing detail view
--- @param source table|nil Navigation source for back-button chain
function XrayBrowser:editSearchTerms(item, category_key, item_title, source)
    local ActionCache = require("koassistant_action_cache")
    local item_name = XrayParser.getItemName(item, category_key)
    local self_ref = self

    -- Load stored user edits
    local all_data = ActionCache.getUserAliases(self.metadata.book_file)
    local user_entry = all_data[item_name] or { add = {}, ignore = {} }
    local user_add = user_entry.add or {}
    local user_ignore = user_entry.ignore or {}

    -- Build lookup sets for classification
    local add_set = {}
    for _idx, a in ipairs(user_add) do add_set[a:lower()] = true end
    local ignore_set = {}
    for _idx, a in ipairs(user_ignore) do ignore_set[a:lower()] = true end

    -- Current in-memory aliases (post-merge: includes user-added, excludes ignored)
    local current_aliases = type(item.aliases) == "table" and item.aliases
        or (item.aliases and { item.aliases } or {})

    local buttons = {}

    -- Active aliases: show with Ignore (AI) or Remove (user-added) action
    for _idx, alias in ipairs(current_aliases) do
        local captured_alias = alias
        local is_user_added = add_set[alias:lower()]
        table.insert(buttons, {{
            text = is_user_added
                and T(_("Remove \"%1\""), alias)
                or T(_("Ignore \"%1\""), alias),
            callback = function()
                UIManager:close(self_ref._edit_dialog)
                self_ref._edit_dialog = nil
                self_ref:_editSearchTermAction(item, category_key, item_title, source,
                    item_name, captured_alias, is_user_added and "remove" or "ignore")
            end,
        }})
    end

    -- Ignored aliases: show with Restore action
    for _idx, alias in ipairs(user_ignore) do
        local captured_alias = alias
        table.insert(buttons, {{
            text = T(_("Restore \"%1\" (ignored)"), alias),
            callback = function()
                UIManager:close(self_ref._edit_dialog)
                self_ref._edit_dialog = nil
                self_ref:_editSearchTermAction(item, category_key, item_title, source,
                    item_name, captured_alias, "restore")
            end,
        }})
    end

    -- Add separator before action buttons
    if #buttons > 0 then
        buttons[#buttons][1].separator = true
    end

    -- Add new + Close row
    table.insert(buttons, {
        {
            text = _("Add new"),
            callback = function()
                UIManager:close(self_ref._edit_dialog)
                self_ref._edit_dialog = nil
                self_ref:_addSearchTermInput(item, category_key, item_title, source, item_name)
            end,
        },
        {
            text = _("Close"),
            id = "close",
            callback = function()
                UIManager:close(self_ref._edit_dialog)
                self_ref._edit_dialog = nil
                -- Refresh detail view to reflect any changes
                self_ref:showItemDetail(item, category_key, item_title, source)
            end,
        },
    })

    self._edit_dialog = ButtonDialog:new{
        title = T(_("Search terms for \"%1\""), item_name),
        buttons = buttons,
    }
    UIManager:show(self._edit_dialog)
end

--- Handle add/remove/ignore/restore actions on search terms
--- @param item table The item data
--- @param category_key string The category key
--- @param item_title string Display title
--- @param source table|nil Navigation source
--- @param item_name string The item display name (storage key)
--- @param alias string The alias being acted on
--- @param action string "remove"|"ignore"|"restore"
function XrayBrowser:_editSearchTermAction(item, category_key, item_title, source, item_name, alias, action)
    local ActionCache = require("koassistant_action_cache")
    local all_data = ActionCache.getUserAliases(self.metadata.book_file)
    local entry = all_data[item_name] or { add = {}, ignore = {} }
    entry.add = entry.add or {}
    entry.ignore = entry.ignore or {}
    local alias_lower = alias:lower()

    if action == "remove" then
        -- Remove user-added alias from storage
        for i = #entry.add, 1, -1 do
            if entry.add[i]:lower() == alias_lower then
                table.remove(entry.add, i)
            end
        end
        -- Remove from in-memory
        if type(item.aliases) == "table" then
            for i = #item.aliases, 1, -1 do
                if item.aliases[i]:lower() == alias_lower then
                    table.remove(item.aliases, i)
                end
            end
        end

    elseif action == "ignore" then
        -- Add to ignore list (if not already there)
        local already = false
        for _idx, ign in ipairs(entry.ignore) do
            if ign:lower() == alias_lower then already = true; break end
        end
        if not already then
            table.insert(entry.ignore, alias)
        end
        -- Remove from in-memory
        if type(item.aliases) == "table" then
            for i = #item.aliases, 1, -1 do
                if item.aliases[i]:lower() == alias_lower then
                    table.remove(item.aliases, i)
                end
            end
        end

    elseif action == "restore" then
        -- Remove from ignore list
        for i = #entry.ignore, 1, -1 do
            if entry.ignore[i]:lower() == alias_lower then
                table.remove(entry.ignore, i)
            end
        end
        -- Add back to in-memory aliases
        if type(item.aliases) ~= "table" then
            item.aliases = item.aliases and { item.aliases } or {}
        end
        table.insert(item.aliases, alias)
    end

    -- Save
    all_data[item_name] = entry
    ActionCache.setUserAliases(self.metadata.book_file, all_data)

    -- Clear distribution cache (forces recount)
    if self._dist_cache then
        self._dist_cache[tostring(item)] = nil
    end

    -- Re-open edit dialog to reflect changes
    self:editSearchTerms(item, category_key, item_title, source)
end

--- Show input dialog to add a new search term
--- @param item table The item data
--- @param category_key string The category key
--- @param item_title string Display title
--- @param source table|nil Navigation source
--- @param item_name string The item display name (storage key)
function XrayBrowser:_addSearchTermInput(item, category_key, item_title, source, item_name)
    local ActionCache = require("koassistant_action_cache")
    local self_ref = self

    local input_dialog
    input_dialog = InputDialog:new{
        title = T(_("Add search term for \"%1\""), item_name),
        input = "",
        input_hint = _("Enter alternate name or spelling"),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                        -- Re-open edit dialog
                        self_ref:editSearchTerms(item, category_key, item_title, source)
                    end,
                },
                {
                    text = _("Add"),
                    is_enter_default = true,
                    callback = function()
                        local new_alias = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if not new_alias or new_alias:match("^%s*$") then
                            self_ref:editSearchTerms(item, category_key, item_title, source)
                            return
                        end
                        new_alias = new_alias:match("^%s*(.-)%s*$")  -- trim

                        -- Load and check duplicates across all terms
                        local all_data = ActionCache.getUserAliases(self_ref.metadata.book_file)
                        local entry = all_data[item_name] or { add = {}, ignore = {} }
                        entry.add = entry.add or {}
                        entry.ignore = entry.ignore or {}
                        local new_lower = new_alias:lower()

                        -- Check existing aliases (both AI and user)
                        local current = type(item.aliases) == "table" and item.aliases or {}
                        for _idx, alias in ipairs(current) do
                            if alias:lower() == new_lower then
                                UIManager:show(InfoMessage:new{
                                    text = _("This search term already exists."),
                                    timeout = 2,
                                })
                                self_ref:editSearchTerms(item, category_key, item_title, source)
                                return
                            end
                        end

                        -- Save to storage
                        table.insert(entry.add, new_alias)
                        all_data[item_name] = entry
                        ActionCache.setUserAliases(self_ref.metadata.book_file, all_data)

                        -- Also remove from ignore if it was previously ignored
                        for i = #entry.ignore, 1, -1 do
                            if entry.ignore[i]:lower() == new_lower then
                                table.remove(entry.ignore, i)
                            end
                        end

                        -- Update in-memory
                        if type(item.aliases) ~= "table" then
                            item.aliases = item.aliases and { item.aliases } or {}
                        end
                        table.insert(item.aliases, new_alias)

                        -- Clear distribution cache
                        if self_ref._dist_cache then
                            self_ref._dist_cache[tostring(item)] = nil
                        end

                        UIManager:show(Notification:new{
                            text = T(_("Added \"%1\""), new_alias),
                        })
                        -- Re-open edit dialog
                        self_ref:editSearchTerms(item, category_key, item_title, source)
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

--- Launch a highlight-context book chat with the given text
--- @param detail_text string The X-Ray detail text to discuss
function XrayBrowser:chatAboutItem(detail_text)
    local Dialogs = require("koassistant_dialogs")  -- Lazy to avoid circular dep
    local config = self.metadata.configuration
    -- Clear context flags for highlight context (matches main.lua highlight pattern)
    config.features.is_general_context = nil
    config.features.is_book_context = nil
    config.features.is_multi_book_context = nil
    config.features.book_metadata = nil
    -- Clear stale selection data - the "highlight" is AI-generated, not a real book selection,
    -- so "Save to Note" must be disabled (prevents saving to a random prior highlight position)
    config.features.selection_data = nil
    -- Hide artifact viewer and filter out actions that use book text / annotations / notebook
    -- (the "highlight" here is AI-generated X-Ray content, not actual book text)
    config.features._hide_artifacts = true
    config.features._exclude_action_flags = { "use_book_text", "use_annotations", "use_notebook" }
    Dialogs.showChatGPTDialog(self.ui, detail_text, config, nil, self.metadata.plugin)
end

-- Short category labels for chapter analysis display
local CHAPTER_CATEGORY_SHORT = {
    characters = _("Cast"),
    key_figures = _("Figures"),
    locations = _("World"),
    themes = _("Ideas"),
    core_concepts = _("Concepts"),
    arguments = _("Args"),
    lexicon = _("Lexicon"),
    terminology = _("Terms"),
    timeline = _("Arc"),
    argument_development = _("Dev"),
}

--- Build an inline bar string for chapter distribution display
--- @param count number Mention count for this chapter
--- @param max_count number Maximum count across all chapters
--- @param bar_width number|nil Number of bar characters (default 8)
--- @return string e.g., "████░░░░  24"
local function buildDistributionBar(count, max_count, bar_width, count_width)
    bar_width = bar_width or 8
    count_width = count_width or #tostring(max_count)
    local count_str = string.format("%" .. count_width .. "d", count)
    if max_count == 0 or count == 0 then
        return string.rep("\u{2591}", bar_width) .. "  " .. count_str
    end
    local filled = math.max(1, math.floor((count / max_count) * bar_width + 0.5))
    if filled > bar_width then filled = bar_width end
    local empty = bar_width - filled
    return string.rep("\u{2588}", filled)
        .. string.rep("\u{2591}", empty)
        .. "  " .. count_str
end

--- Show chapter picker for Mentions navigation.
--- Opens a KOReader-style hierarchical TOC as a full-screen modal with
--- expand/collapse, indentation, and spoiler gating.
--- @param current_chapter table|string|nil Current selection ("all" or chapter table)
function XrayBrowser:showChapterPicker(current_chapter)
    local BD = require("ui/bidi")
    local Blitbuffer = require("ffi/blitbuffer")
    local Button = require("ui/widget/button")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local Size = require("ui/size")
    local TextWidget = require("ui/widget/textwidget")

    local self_ref = self

    -- Get hierarchical TOC (all depths)
    local entries, max_depth = getHierarchicalChapters(self.ui, self.coverage_page)
    if not entries or #entries == 0 then
        -- Fallback: page-range chunks (flat, no hierarchy)
        local chunks = getAllPageRangeChapters(self.ui, self.coverage_page)
        if not chunks or #chunks == 0 then return end
        self:_showFlatChapterPicker(chunks, current_chapter)
        return
    end

    -- Calculate indentation unit: width of 4 spaces (same as KOReader TOC)
    local items_font_size = 18
    local tmp = TextWidget:new{
        text = "    ",
        face = Font:getFace("smallinfofont", items_font_size),
    }
    local toc_indent = tmp:getSize().w
    tmp:free()

    -- Build full TOC array with indent, depth, page range fields
    local full_toc = {}
    for i, entry in ipairs(entries) do
        local d = entry.depth or 1
        local title = entry.title
        if not title or title == "" then title = T(_("Page %1"), entry.start_page) end
        table.insert(full_toc, {
            text = title,
            mandatory = entry.start_page,
            indent = toc_indent * (d - 1),
            depth = d,
            index = i,
            start_page = entry.start_page,
            end_page = entry.end_page,
            is_current = entry.is_current,
            unread = entry.unread,
            dim = entry.unread and not self._mentions_spoiler_warned,
        })
    end

    -- Expand/collapse button sizing (same calculation as KOReader TOC)
    local items_per_page = 14
    local icon_size = math.floor(Screen:getHeight() / items_per_page * 2 / 5)
    local button_width = icon_size * 2

    -- Detect parent nodes (reverse pass: if depth < next entry's depth, it's a parent)
    local can_collapse = max_depth > 1
    if can_collapse then
        local depth = 0
        for i = #full_toc, 1, -1 do
            local v = full_toc[i]
            if v.depth < depth then
                v._is_parent = true
            end
            depth = v.depth
        end
    end

    -- State: expanded_nodes tracks which full_toc indices are expanded
    local expanded_nodes = {}

    -- Build initial collapsed view (only top-level entries if multi-depth)
    local collapse_depth = 2
    local collapsed_toc = {}
    if can_collapse then
        for _idx, v in ipairs(full_toc) do
            if v.depth < collapse_depth then
                table.insert(collapsed_toc, v)
            end
        end
    else
        for _idx, v in ipairs(full_toc) do
            table.insert(collapsed_toc, v)
        end
    end

    -- Prepend "All Chapters" option(s)
    if self.is_complete then
        table.insert(collapsed_toc, 1, {
            text = _("All Chapters"),
            bold = current_chapter == "all",
            separator = true,
            _is_all_chapters = true,
        })
    else
        -- Two options: scoped (spoiler-safe) and reveal-all (entire book)
        table.insert(collapsed_toc, 1, {
            text = T(_("All Chapters (to %1)"), self.metadata.progress or "?%"),
            bold = current_chapter == "all",
            _is_all_chapters = true,
        })
        table.insert(collapsed_toc, 2, {
            text = _("All Chapters"),
            bold = current_chapter == "all_reveal",
            dim = not self._mentions_spoiler_warned,
            separator = true,
            _is_all_reveal = true,
        })
    end

    -- Create the TOC menu (separate full-screen widget, not part of browser nav stack)
    local toc_menu = Menu:new{
        title = _("Table of Contents"),
        state_w = can_collapse and button_width or 0,
        is_borderless = true,
        is_popout = false,
        single_line = true,
        align_baselines = true,
        with_dots = true,
        items_per_page = items_per_page,
        items_font_size = items_font_size,
        items_mandatory_font_size = items_font_size - 4,
        items_padding = can_collapse and math.floor(Size.padding.fullscreen / 2) or nil,
        line_color = Blitbuffer.COLOR_WHITE,
    }

    local menu_container = CenterContainer:new{
        dimen = Screen:getSize(),
        covers_fullscreen = true,
        toc_menu,
    }

    -- Create expand/collapse buttons (after menu, for show_parent)
    local expand_button = Button:new{
        icon = "control.expand",
        icon_rotation_angle = BD.mirroredUILayout() and 180 or 0,
        width = button_width,
        icon_width = icon_size,
        icon_height = icon_size,
        bordersize = 0,
        show_parent = menu_container,
        callback = function() end, -- replaced below
        onTapSelectButton = function() end, -- pass through to onMenuSelect
    }
    local collapse_button = Button:new{
        icon = "control.collapse",
        width = button_width,
        icon_width = icon_size,
        icon_height = icon_size,
        bordersize = 0,
        show_parent = menu_container,
        callback = function() end,
        onTapSelectButton = function() end,
    }

    -- Assign expand/collapse state to parent nodes
    if can_collapse then
        for _idx, v in ipairs(full_toc) do
            if v._is_parent then
                v.state = expand_button:new{}
            end
        end
    end

    -- Determine which entry to auto-expand and bold:
    -- If a specific chapter was previously selected, target that; otherwise reading position
    local target_ft_idx
    if can_collapse then
        if type(current_chapter) == "table" and current_chapter.start_page then
            -- Previously selected chapter — find it in full_toc
            for i, v in ipairs(full_toc) do
                if v.start_page == current_chapter.start_page
                        and v.depth == (current_chapter.depth or v.depth) then
                    target_ft_idx = i
                    break
                end
            end
        end
        if not target_ft_idx then
            -- Default: deepest is_current entry (reading position)
            for i, v in ipairs(full_toc) do
                if v.is_current then
                    target_ft_idx = i  -- keep overwriting → deepest wins
                end
            end
        end
    end

    -- Auto-expand ancestor chain so the target entry is visible
    if target_ft_idx and can_collapse and full_toc[target_ft_idx].depth >= collapse_depth then
        -- Collect ancestors that need expanding (walk backward for each parent depth)
        local ancestors = {}
        local need_depth = full_toc[target_ft_idx].depth - 1
        for i = target_ft_idx - 1, 1, -1 do
            if full_toc[i].depth == need_depth then
                table.insert(ancestors, 1, i)  -- prepend to maintain order
                need_depth = need_depth - 1
                if need_depth < 1 then break end  -- depth 1 already visible
            end
        end
        -- Expand each ancestor: insert its immediate children into collapsed_toc
        for _idx, anc_idx in ipairs(ancestors) do
            expanded_nodes[anc_idx] = true
            local anc = full_toc[anc_idx]
            -- Find position in collapsed_toc
            local ci
            for j, cv in ipairs(collapsed_toc) do
                if cv.start_page == anc.start_page and cv.depth == anc.depth
                        and cv.text == anc.text then
                    ci = j
                    break
                end
            end
            if ci then
                for j = anc_idx + 1, #full_toc do
                    local v = full_toc[j]
                    if v.depth == anc.depth + 1 then
                        ci = ci + 1
                        table.insert(collapsed_toc, ci, v)
                    elseif v.depth <= anc.depth then
                        break
                    end
                end
                -- Switch to collapse icon
                if anc.state then anc.state:free() end
                anc.state = collapse_button:new{}
            end
        end
    end

    -- Bold highlighting: target the selected chapter, or deepest is_current (reading position)
    if target_ft_idx then
        local target = full_toc[target_ft_idx]
        for i, v in ipairs(collapsed_toc) do
            if not v._is_all_chapters and not v._is_all_reveal
                    and v.start_page == target.start_page and v.depth == target.depth then
                collapsed_toc.current = i
                break
            end
        end
    end
    if not collapsed_toc.current then
        -- Fallback: deepest is_current in collapsed view
        for i = #collapsed_toc, 1, -1 do
            local v = collapsed_toc[i]
            if not v._is_all_chapters and not v._is_all_reveal and v.is_current then
                collapsed_toc.current = i
                break
            end
        end
    end

    -- Expand: insert immediate children into collapsed_toc
    local function expandTocNode(index)
        if expanded_nodes[index] then return end
        expanded_nodes[index] = true
        local cur_node = full_toc[index]
        local cur_depth = cur_node.depth
        -- Find position in collapsed_toc
        local collapsed_index
        for i, v in ipairs(collapsed_toc) do
            if v.start_page == cur_node.start_page and v.depth == cur_depth
                    and v.text == cur_node.text then
                collapsed_index = i
                break
            end
        end
        if not collapsed_index then return end
        for i = index + 1, #full_toc do
            local v = full_toc[i]
            if v.depth == cur_depth + 1 then
                collapsed_index = collapsed_index + 1
                table.insert(collapsed_toc, collapsed_index, v)
            elseif v.depth <= cur_depth then
                break
            end
        end
        if cur_node.state then cur_node.state:free() end
        cur_node.state = collapse_button:new{}
        toc_menu:switchItemTable(nil, collapsed_toc, -1)
    end

    -- Collapse: remove all descendants from collapsed_toc
    local function collapseTocNode(index)
        if not expanded_nodes[index] then return end
        expanded_nodes[index] = nil
        local cur_node = full_toc[index]
        local cur_depth = cur_node.depth
        local i = 1
        local is_child_node = false
        while i <= #collapsed_toc do
            local v = collapsed_toc[i]
            if is_child_node then
                if v.depth and v.depth <= cur_depth then
                    is_child_node = false
                    i = i + 1
                else
                    -- Descendant: collapse and remove
                    if v.state then
                        v.state:free()
                        if v._is_parent then
                            v.state = expand_button:new{}
                        end
                        if v.index and expanded_nodes[v.index] then
                            expanded_nodes[v.index] = nil
                        end
                    end
                    table.remove(collapsed_toc, i)
                end
            else
                if v.start_page == cur_node.start_page and v.depth == cur_depth
                        and v.text == cur_node.text then
                    is_child_node = true
                end
                i = i + 1
            end
        end
        cur_node.state:free()
        cur_node.state = expand_button:new{}
        toc_menu:switchItemTable(nil, collapsed_toc, -1)
    end

    -- Wire button callbacks
    expand_button.callback = function(index) expandTocNode(index) end
    collapse_button.callback = function(index) collapseTocNode(index) end

    -- Helper: select a chapter and show mentions
    local function selectChapter(chapter_data)
        UIManager:close(menu_container)
        -- Pop the current Mentions results (modal doesn't use nav stack)
        self_ref:navigateBack()
        self_ref:showMentions(chapter_data)
    end

    -- Override onMenuSelect: left-zone tap toggles expand/collapse, rest selects chapter
    function toc_menu:onMenuSelect(item, pos)
        -- Expand/collapse zone check (same as KOReader TOC)
        if item.state and pos and pos.x then
            local do_toggle = BD.mirroredUILayout() and pos.x > 0.7 or pos.x < 0.3
            if do_toggle then
                item.state.callback(item.index)
                return true
            end
        end
        if item._is_all_chapters then
            selectChapter("all")
        elseif item._is_all_reveal then
            if not self_ref._mentions_spoiler_warned then
                self_ref._spoiler_dialog = ButtonDialog:new{
                    text = _("This will scan beyond your X-Ray coverage.\n\nReveal all mentions?"),
                    buttons = {
                        {{
                            text = _("Cancel"),
                            callback = function()
                                UIManager:close(self_ref._spoiler_dialog)
                            end,
                        }},
                        {{
                            text = _("Reveal"),
                            callback = function()
                                UIManager:close(self_ref._spoiler_dialog)
                                self_ref._mentions_spoiler_warned = true
                                selectChapter("all_reveal")
                            end,
                        }},
                    },
                }
                UIManager:show(self_ref._spoiler_dialog)
            else
                selectChapter("all_reveal")
            end
        elseif item.unread then
            if not self_ref._mentions_spoiler_warned then
                self_ref._spoiler_dialog = ButtonDialog:new{
                    text = _("This chapter is beyond your X-Ray coverage.\n\nReveal mentions?"),
                    buttons = {
                        {{
                            text = _("Cancel"),
                            callback = function()
                                UIManager:close(self_ref._spoiler_dialog)
                            end,
                        }},
                        {{
                            text = _("Reveal"),
                            callback = function()
                                UIManager:close(self_ref._spoiler_dialog)
                                self_ref._mentions_spoiler_warned = true
                                selectChapter({
                                    title = item.text,
                                    start_page = item.start_page,
                                    end_page = item.end_page,
                                    depth = item.depth,
                                })
                            end,
                        }},
                    },
                }
                UIManager:show(self_ref._spoiler_dialog)
            else
                selectChapter({
                    title = item.text,
                    start_page = item.start_page,
                    end_page = item.end_page,
                    depth = item.depth,
                })
            end
        else
            selectChapter({
                title = item.text,
                start_page = item.start_page,
                end_page = item.end_page,
                depth = item.depth,
            })
        end
        return true
    end

    -- Long-press: show full title (same as KOReader TOC)
    function toc_menu:onMenuHold(item)
        if not Device:isTouchDevice() and item.state then
            item.state.callback(item.index)
        else
            UIManager:show(InfoMessage:new{
                show_icon = false,
                text = item.text or "",
            })
        end
        return true
    end

    toc_menu.close_callback = function()
        UIManager:close(menu_container)
    end
    toc_menu.show_parent = menu_container

    toc_menu:switchItemTable(nil, collapsed_toc, collapsed_toc.current or -1)
    UIManager:show(menu_container)
end

--- Flat chapter picker fallback for books without usable TOC.
--- Shows page-range chunks in a modal Menu.
--- @param chunks table Array from getAllPageRangeChapters
--- @param current_chapter table|string|nil Current selection
function XrayBrowser:_showFlatChapterPicker(chunks, current_chapter)
    local Blitbuffer = require("ffi/blitbuffer")
    local CenterContainer = require("ui/widget/container/centercontainer")

    local self_ref = self
    local items = {}

    -- "All Chapters" at top
    if self.is_complete then
        table.insert(items, {
            text = _("All Chapters"),
            bold = current_chapter == "all",
            separator = true,
            _is_all_chapters = true,
        })
    else
        table.insert(items, {
            text = T(_("All Chapters (to %1)"), self.metadata.progress or "?%"),
            bold = current_chapter == "all",
            _is_all_chapters = true,
        })
        table.insert(items, {
            text = _("All Chapters"),
            bold = current_chapter == "all_reveal",
            dim = not self._mentions_spoiler_warned,
            separator = true,
            _is_all_reveal = true,
        })
    end

    -- Page-range chunks
    for _idx, ch in ipairs(chunks) do
        table.insert(items, {
            text = ch.title or "",
            mandatory = ch.start_page,
            mandatory_dim = true,
            dim = ch.unread and not self._mentions_spoiler_warned,
            _chapter = ch,
        })
        if ch.is_current then
            items.current = #items
        end
    end

    local toc_menu = Menu:new{
        title = _("Table of Contents"),
        is_borderless = true,
        is_popout = false,
        single_line = true,
        align_baselines = true,
        with_dots = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        line_color = Blitbuffer.COLOR_WHITE,
    }

    local menu_container = CenterContainer:new{
        dimen = Screen:getSize(),
        covers_fullscreen = true,
        toc_menu,
    }

    function toc_menu:onMenuSelect(item)
        if item._is_all_chapters then
            UIManager:close(menu_container)
            self_ref:navigateBack()
            self_ref:showMentions("all")
        elseif item._is_all_reveal then
            if not self_ref._mentions_spoiler_warned then
                self_ref._spoiler_dialog = ButtonDialog:new{
                    text = _("This will scan beyond your X-Ray coverage.\n\nReveal all mentions?"),
                    buttons = {
                        {{
                            text = _("Cancel"),
                            callback = function()
                                UIManager:close(self_ref._spoiler_dialog)
                            end,
                        }},
                        {{
                            text = _("Reveal"),
                            callback = function()
                                UIManager:close(self_ref._spoiler_dialog)
                                self_ref._mentions_spoiler_warned = true
                                UIManager:close(menu_container)
                                self_ref:navigateBack()
                                self_ref:showMentions("all_reveal")
                            end,
                        }},
                    },
                }
                UIManager:show(self_ref._spoiler_dialog)
            else
                UIManager:close(menu_container)
                self_ref:navigateBack()
                self_ref:showMentions("all_reveal")
            end
        elseif item._chapter then
            local ch = item._chapter
            if ch.unread then
                if not self_ref._mentions_spoiler_warned then
                    self_ref._spoiler_dialog = ButtonDialog:new{
                        text = _("This chapter is beyond your X-Ray coverage.\n\nReveal mentions?"),
                        buttons = {
                            {{
                                text = _("Cancel"),
                                callback = function()
                                    UIManager:close(self_ref._spoiler_dialog)
                                end,
                            }},
                            {{
                                text = _("Reveal"),
                                callback = function()
                                    UIManager:close(self_ref._spoiler_dialog)
                                    self_ref._mentions_spoiler_warned = true
                                    UIManager:close(menu_container)
                                    self_ref:navigateBack()
                                    self_ref:showMentions(ch)
                                end,
                            }},
                        },
                    }
                    UIManager:show(self_ref._spoiler_dialog)
                else
                    UIManager:close(menu_container)
                    self_ref:navigateBack()
                    self_ref:showMentions(ch)
                end
            else
                UIManager:close(menu_container)
                self_ref:navigateBack()
                self_ref:showMentions(ch)
            end
        end
        return true
    end

    function toc_menu:onMenuHold(item)
        UIManager:show(InfoMessage:new{
            show_icon = false,
            text = item.text or "",
        })
        return true
    end

    toc_menu.close_callback = function()
        UIManager:close(menu_container)
    end
    toc_menu.show_parent = menu_container

    toc_menu:switchItemTable(nil, items, items.current or -1)
    UIManager:show(menu_container)
end

--- Unified Mentions: show X-Ray items in a chapter, all chapters, or specific chapter.
--- @param chapter table|string|nil nil=current chapter, "all"=aggregate, table=specific chapter
function XrayBrowser:showMentions(chapter)
    if not self.ui or not self.ui.document then
        UIManager:show(InfoMessage:new{
            text = _("No book open."),
            timeout = 3,
        })
        return
    end

    -- Determine notification text
    local is_all = (chapter == "all" or chapter == "all_reveal")
    local notif_text = is_all and _("Analyzing book…") or _("Analyzing chapter…")
    UIManager:show(Notification:new{ text = notif_text })

    local self_ref = self
    UIManager:scheduleIn(0.2, function()
        local text, chapter_title
        local display_chapter = chapter  -- track what we're showing for the picker

        if is_all then
            -- Aggregate: page 1 to end
            -- "all" = scoped to max(coverage, reading); "all_reveal" = entire book
            local total_pages = self_ref.ui.document.info.number_of_pages or 0
            if total_pages == 0 then
                UIManager:show(InfoMessage:new{
                    text = _("Could not determine book length."),
                    timeout = 3,
                })
                return
            end
            local end_page
            if chapter == "all_reveal" then
                end_page = total_pages
            else
                local current_page = getCurrentPage(self_ref.ui)
                end_page = current_page
                if self_ref.coverage_page then
                    end_page = math.max(self_ref.coverage_page, current_page)
                end
                if end_page > total_pages then end_page = total_pages end
            end
            local all_chapter = { start_page = 1, end_page = end_page }
            text = self_ref:_getChapterText(all_chapter)
            chapter_title = ""
        elseif type(chapter) == "table" then
            -- Specific chapter from picker
            text = self_ref:_getChapterText(chapter)
            chapter_title = chapter.title or ""
        else
            -- Current chapter (default — deepest TOC match)
            text, chapter_title = getCurrentChapterText(self_ref.ui, nil, self_ref)
        end

        if not text or text == "" then
            local msg
            if is_all then
                msg = self_ref.ui.document.info.has_pages
                    and _("Could not extract book text. PDF text extraction may not be available for this document.")
                    or _("Could not extract book text.")
            else
                msg = self_ref.ui.document.info.has_pages
                    and _("Could not extract chapter text. PDF text extraction may not be available for this document.")
                    or _("Could not extract chapter text.")
            end
            UIManager:show(InfoMessage:new{
                text = msg,
                timeout = 5,
            })
            return
        end

        local found = XrayParser.findItemsInChapter(self_ref.xray_data, text)

        if #found == 0 then
            local msg
            if is_all then
                msg = _("No X-Ray items found in book text.")
            elseif chapter_title and chapter_title ~= "" then
                msg = T(_("No X-Ray items found in \"%1\"."), chapter_title)
            else
                msg = _("No X-Ray items found in current chapter.")
            end
            UIManager:show(InfoMessage:new{
                text = msg,
                timeout = 4,
            })
            return
        end

        -- Build menu items
        local items = {}

        -- Chapter picker button at top
        local picker_label
        local chapter_depth = type(chapter) == "table" and chapter.depth or nil
        if is_all then
            if chapter == "all_reveal" or self_ref.is_complete then
                picker_label = _("All Chapters \u{25BE}")
            else
                picker_label = T(_("To %1 \u{25BE}"), self_ref.metadata.progress or "?%")
            end
        elseif chapter_title and chapter_title ~= "" then
            picker_label = chapter_title .. " \u{25BE}"
        else
            picker_label = _("This Chapter \u{25BE}")
        end

        table.insert(items, {
            text = picker_label,
            mandatory = chapter_depth and chapter_depth > 1 and ("Lv." .. chapter_depth) or nil,
            mandatory_dim = true,
            bold = true,
            callback = function()
                self_ref:showChapterPicker(display_chapter)
            end,
            separator = true,
        })

        -- Item list
        for _idx, entry in ipairs(found) do
            local name = XrayParser.getItemName(entry.item, entry.category_key)
            local short_cat = CHAPTER_CATEGORY_SHORT[entry.category_key] or entry.category_label
            local captured = entry
            table.insert(items, {
                text = name,
                mandatory = string.format("[%s] %s", short_cat, T(_("%1x"), entry.count)),
                mandatory_dim = true,
                callback = function()
                    self_ref:showItemDetail(captured.item, captured.category_key, name)
                end,
            })
        end

        -- Title
        local title
        if is_all then
            if chapter == "all_reveal" or self_ref.is_complete then
                title = T(_("All Chapters — %1 mentions"), #found)
            else
                title = T(_("To %1 — %2 mentions"), self_ref.metadata.progress or "?%", #found)
            end
        elseif chapter_title and chapter_title ~= "" then
            title = T(_("%1 — %2 mentions"), chapter_title, #found)
        else
            title = T(_("This Chapter — %1 mentions"), #found)
        end

        self_ref:navigateForward(title, items)
    end)
end

--- Show all X-Ray items in a specific chapter (given boundaries)
--- Called from distribution view when tapping a chapter.
--- Unlike showMentions(), takes arbitrary chapter boundaries
--- and does not include a TOC depth picker.
--- @param chapter table {title, start_page, end_page}
function XrayBrowser:showChapterItemsAt(chapter)
    if not self.ui or not self.ui.document then
        UIManager:show(InfoMessage:new{
            text = _("No book open."),
            timeout = 3,
        })
        return
    end

    UIManager:show(Notification:new{
        text = _("Analyzing chapter…"),
    })

    local self_ref = self
    UIManager:scheduleIn(0.2, function()
        local text = self_ref:_getChapterText(chapter)

        if not text or text == "" then
            local msg = self_ref.ui.document.info.has_pages
                and _("Could not extract chapter text. PDF text extraction may not be available for this document.")
                or _("Could not extract chapter text.")
            UIManager:show(InfoMessage:new{
                text = msg,
                timeout = 5,
            })
            return
        end

        local found = XrayParser.findItemsInChapter(self_ref.xray_data, text)

        if #found == 0 then
            local msg = chapter.title and chapter.title ~= ""
                and T(_("No X-Ray items found in \"%1\"."), chapter.title)
                or _("No X-Ray items found in this chapter.")
            UIManager:show(InfoMessage:new{
                text = msg,
                timeout = 4,
            })
            return
        end

        local items = {}
        for _idx, entry in ipairs(found) do
            local name = XrayParser.getItemName(entry.item, entry.category_key)
            local short_cat = CHAPTER_CATEGORY_SHORT[entry.category_key] or entry.category_label
            local captured = entry
            table.insert(items, {
                text = name,
                mandatory = string.format("[%s] %s", short_cat, T(_("%1x"), entry.count)),
                mandatory_dim = true,
                callback = function()
                    self_ref:showItemDetail(captured.item, captured.category_key, name)
                end,
            })
        end

        local title
        if chapter.title and chapter.title ~= "" then
            title = T(_("%1 — %2 mentions"), chapter.title, #found)
        else
            title = T(_("Chapter — %1 mentions"), #found)
        end

        self_ref:navigateForward(title, items)
    end)
end

--- Build distribution menu items and display them
--- Called by showItemDistribution for both initial render and in-place refresh
--- @param item table The X-Ray item
--- @param category_key string Category key
--- @param item_title string Display name for the item
--- @param data table Mutable distribution state {chapters, chapter_counts, max_count, ...}
--- @param is_refresh boolean If true, update menu in-place; if false, navigateForward
function XrayBrowser:_buildDistributionView(item, category_key, item_title, data, is_refresh)
    local self_ref = self
    local chapters = data.chapters
    local chapter_counts = data.chapter_counts
    local count_width = data.max_count > 0 and #tostring(data.max_count) or 1

    local items = {}
    for i, chapter in ipairs(chapters) do
        local count = chapter_counts[i]
        local display_title = chapter.title or ""
        local captured_chapter = chapter

        if not count then
            -- Unread chapter: dimmed, tap to reveal individually
            local captured_i = i
            table.insert(items, {
                text = display_title,
                mandatory = "···",
                mandatory_dim = true,
                dim = true,
                callback = function()
                    local function do_reveal()
                        UIManager:show(Notification:new{
                            text = _("Scanning…"),
                        })
                        UIManager:scheduleIn(0.1, function()
                            local _raw, lower = self_ref:_getChapterText(captured_chapter)
                            local ch_count = 0
                            if lower ~= "" then
                                ch_count = XrayParser.countItemOccurrences(item, lower)
                            end
                            -- Update mutable state
                            chapter_counts[captured_i] = ch_count
                            data.total_mentions = data.total_mentions + ch_count
                            data.scanned_count = data.scanned_count + 1
                            if ch_count > data.max_count then
                                data.max_count = ch_count
                            end
                            -- Check if any unread remain
                            local still_unread = false
                            for j = 1, #chapters do
                                if chapters[j].unread and chapter_counts[j] == nil then
                                    still_unread = true
                                    break
                                end
                            end
                            data.has_unread = still_unread
                            -- Rebuild menu in-place, preserving scroll to revealed item
                            data._focus_idx = captured_i
                            self_ref:_buildDistributionView(item, category_key, item_title, data, true)
                        end)
                    end
                    if not data.spoiler_warned then
                        local confirm_dialog
                        confirm_dialog = ButtonDialog:new{
                            text = _("This chapter is beyond your X-Ray coverage and may contain spoilers.\n\nReveal mentions?"),
                            buttons = {{
                                {
                                    text = _("Cancel"),
                                    callback = function()
                                        UIManager:close(confirm_dialog)
                                    end,
                                },
                                {
                                    text = _("Reveal"),
                                    callback = function()
                                        UIManager:close(confirm_dialog)
                                        data.spoiler_warned = true
                                        do_reveal()
                                    end,
                                },
                            }},
                        }
                        UIManager:show(confirm_dialog)
                    else
                        do_reveal()
                    end
                end,
            })
        else
            -- Mark current chapter with ▶
            if chapter.is_current then
                display_title = "\u{25B6} " .. display_title
            end
            table.insert(items, {
                text = display_title,
                mandatory = buildDistributionBar(count, data.max_count, nil, count_width),
                mandatory_dim = (count == 0),
                callback = function()
                    if count > 0 then
                        local captured_ui = self_ref.ui
                        -- Build search term: full display name + aliases with regex OR (|)
                        -- e.g., "Edward Said" with aliases "Said" → Edward Said|Said
                        local search_name = item.name or item.term or item.event or item_title
                        -- Strip parenthetical: "Theosis (Deification)" → "Theosis"
                        search_name = search_name:gsub("%s*%(.-%)%s*", "")
                        search_name = search_name:match("^%s*(.-)%s*$") or search_name
                        -- Collect aliases as full terms
                        -- Deduplicate: skip aliases that match the main search term
                        local alias_terms = {}
                        local search_lower = search_name:lower()
                        if type(item.aliases) == "table" then
                            for _idx, alias in ipairs(item.aliases) do
                                if #alias > 2 then
                                    local clean = alias:gsub("%s*%(.-%)%s*", "")
                                    clean = clean:match("^%s*(.-)%s*$") or clean
                                    if #clean > 2 and clean:lower() ~= search_lower then
                                        table.insert(alias_terms, clean)
                                    end
                                end
                            end
                        end
                        if captured_ui.search and #search_name > 2 then
                            -- Close browser, navigate to chapter, then search
                            local function navigateAndSearch(term, use_regex)
                                UIManager:close(self_ref.menu)
                                captured_ui:handleEvent(Event:new("GotoPage", captured_chapter.start_page))
                                UIManager:scheduleIn(0.2, function()
                                    if use_regex then
                                        captured_ui.search.last_search_text = term
                                        captured_ui.search.use_regex = true
                                        captured_ui.search.case_insensitive = true
                                        captured_ui.search:onShowSearchDialog(term, 0, true, true)
                                    else
                                        captured_ui.search:searchCallback(0, term)
                                    end
                                end)
                            end
                            -- PDF documents don't support regex search (no getAndClearRegexSearchError)
                            local can_regex = not captured_ui.document.info.has_pages
                            if not can_regex and #alias_terms > 0 then
                                -- PDF with aliases: show picker for which term to search
                                local buttons = {}
                                -- Main name as first button
                                table.insert(buttons, {{
                                    text = search_name,
                                    callback = function()
                                        UIManager:close(self_ref._search_picker)
                                        navigateAndSearch(search_name, false)
                                    end,
                                }})
                                -- Each alias as a separate button
                                for _idx2, a in ipairs(alias_terms) do
                                    table.insert(buttons, {{
                                        text = a,
                                        callback = function()
                                            UIManager:close(self_ref._search_picker)
                                            navigateAndSearch(a, false)
                                        end,
                                    }})
                                end
                                self_ref._search_picker = ButtonDialog:new{
                                    title = _("Search for:"),
                                    buttons = buttons,
                                }
                                UIManager:show(self_ref._search_picker)
                            elseif can_regex and #alias_terms > 0 then
                                -- EPUB: regex OR pattern with all terms
                                local function esc(s)
                                    return s:gsub("([%.%+%*%?%[%]%^%$%(%)%{%}%|\\])", "\\%1")
                                end
                                local pattern = esc(search_name)
                                for _idx2, a in ipairs(alias_terms) do
                                    pattern = pattern .. "|" .. esc(a)
                                end
                                navigateAndSearch(pattern, true)
                            else
                                -- No aliases or single term: plain search
                                navigateAndSearch(search_name, false)
                            end
                        end
                    else
                        UIManager:show(Notification:new{
                            text = T(_("No X-Ray items in \"%1\"."),
                                captured_chapter.title or _("this chapter")),
                        })
                    end
                end,
            })
        end
    end

    -- "Scan all chapters" footer when there are unread chapters
    if data.has_unread then
        table.insert(items, {
            text = _("Scan all chapters"),
            mandatory = _("may contain spoilers"),
            mandatory_dim = true,
            bold = true,
            separator = true,
            callback = function()
                UIManager:show(Notification:new{
                    text = _("Scanning all chapters…"),
                })
                UIManager:scheduleIn(0.2, function()
                    for j = 1, #chapters do
                        if chapter_counts[j] == nil then
                            local _raw, lower = self_ref:_getChapterText(chapters[j])
                            local ch_count = 0
                            if lower ~= "" then
                                ch_count = XrayParser.countItemOccurrences(item, lower)
                            end
                            chapter_counts[j] = ch_count
                            data.total_mentions = data.total_mentions + ch_count
                            data.scanned_count = data.scanned_count + 1
                            if ch_count > data.max_count then
                                data.max_count = ch_count
                            end
                        end
                    end
                    data.has_unread = false
                    data.spoiler_warned = true
                    data._focus_idx = nil  -- reset to top after scanning all
                    self_ref:_buildDistributionView(item, category_key, item_title, data, true)
                end)
            end,
        })
    end

    local title = T(_("%1 — %2 chapters"), item_title,
        data.has_unread and data.scanned_count or #chapters)

    if is_refresh then
        -- Update menu in-place, preserving scroll position
        self.current_title = title
        self.menu:switchItemTable(title, items, data._focus_idx)
    else
        self:navigateForward(title, items)
    end
end

--- Show distribution of a single item's mentions across all chapters
--- Entry point: "Chapter Appearances" button in item detail view
--- @param item table The X-Ray item
--- @param category_key string Category key
--- @param item_title string Display name for the item
function XrayBrowser:showItemDistribution(item, category_key, item_title)
    if not self.ui or not self.ui.document then
        UIManager:show(InfoMessage:new{
            text = _("No book open."),
            timeout = 3,
        })
        return
    end

    -- Check per-session cache (keyed by item table reference)
    self._dist_cache = self._dist_cache or {}
    local cache_key = tostring(item)
    local cached = self._dist_cache[cache_key]
    if cached then
        self:_buildDistributionView(item, category_key, item_title, cached, false)
        return
    end

    UIManager:show(Notification:new{
        text = _("Computing distribution…"),
    })

    local self_ref = self
    UIManager:scheduleIn(0.2, function()
        -- Get all chapters (pass coverage_page for spoiler gating)
        local chapters, _toc_info = getAllChapterBoundaries(self_ref.ui, nil, self_ref.coverage_page)
        if not chapters then
            chapters, _toc_info = getAllPageRangeChapters(self_ref.ui, self_ref.coverage_page)
        end
        if not chapters or #chapters == 0 then
            UIManager:show(InfoMessage:new{
                text = _("Could not determine chapter structure."),
                timeout = 3,
            })
            return
        end

        -- Count mentions in each chapter (skip unread)
        local chapter_counts = {}
        local max_count = 0
        local total_mentions = 0
        local scanned_count = 0
        local has_unread = false
        for _idx, chapter in ipairs(chapters) do
            if chapter.unread then
                has_unread = true
                -- chapter_counts[i] left nil implicitly (unread = not yet scanned)
            else
                scanned_count = scanned_count + 1
                local _raw, lower = self_ref:_getChapterText(chapter)
                local count = 0
                if lower ~= "" then
                    count = XrayParser.countItemOccurrences(item, lower)
                end
                chapter_counts[_idx] = count
                total_mentions = total_mentions + count
                if count > max_count then max_count = count end
            end
        end

        if total_mentions == 0 and scanned_count > 0 then
            local msg = self_ref.ui.document.info.has_pages
                and T(_("No mentions of \"%1\" found. PDF text extraction may not be available for this document."), item_title)
                or T(_("No mentions of \"%1\" found in book text."), item_title)
            UIManager:show(InfoMessage:new{
                text = msg,
                timeout = 5,
            })
            return
        end

        local data = {
            chapters = chapters,
            chapter_counts = chapter_counts,
            max_count = max_count,
            total_mentions = total_mentions,
            scanned_count = scanned_count,
            has_unread = has_unread,
            spoiler_warned = false,
        }
        self_ref._dist_cache[cache_key] = data
        self_ref:_buildDistributionView(item, category_key, item_title, data, false)
    end)
end

--- Show search dialog (overlays as InputDialog)
function XrayBrowser:showSearch()
    local self_ref = self

    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Search X-Ray"),
        input = "",
        input_hint = _("Name, term, description..."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if query and query ~= "" then
                            self_ref:showSearchResults(query)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

--- Show search results (navigates forward)
--- @param query string The search query
function XrayBrowser:showSearchResults(query)
    local results = XrayParser.searchAll(self.xray_data, query)

    if #results == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("No results for \"%1\"."), query),
            timeout = 3,
        })
        return
    end

    local items = {}
    local self_ref = self

    for _idx, result in ipairs(results) do
        local item = result.item
        local name = XrayParser.getItemName(item, result.category_key)
        local match_label = result.category_label
        if result.match_field == "alias" then
            match_label = match_label .. " (" .. _("alias") .. ")"
        elseif result.match_field == "description" then
            match_label = match_label .. " (" .. _("desc.") .. ")"
        end

        local captured_item = item
        local captured_key = result.category_key
        table.insert(items, {
            text = name,
            mandatory = match_label,
            mandatory_dim = true,
            callback = function()
                self_ref:showItemDetail(captured_item, captured_key, name)
            end,
        })
    end

    local title = T(_("Results for \"%1\" (%2)"), query, #results)
    self:navigateForward(title, items)
end

--- Show full rendered markdown view in ChatGPTViewer (overlays on menu)
function XrayBrowser:showFullView()
    local ChatGPTViewer = require("koassistant_chatgptviewer")

    local markdown = XrayParser.renderToMarkdown(
        self.xray_data,
        self.metadata.title or "",
        self.metadata.progress or ""
    )

    -- Build title: X-Ray (XX%) - Book Title
    local title = "X-Ray"
    if self.metadata.progress then
        title = title .. " (" .. self.metadata.progress .. ")"
    end
    if self.metadata.title then
        title = title .. " - " .. self.metadata.title
    end

    -- Build metadata info line for display at top of content
    local info_parts = { "X-Ray" }
    if self.metadata.progress then
        local progress_label = self.metadata.progress
        if self.metadata.previous_progress then
            progress_label = progress_label .. " (" .. _("updated from") .. " " .. self.metadata.previous_progress .. ")"
        end
        table.insert(info_parts, progress_label)
    end
    if self.metadata.source_label then
        table.insert(info_parts, self.metadata.source_label)
    end
    if self.metadata.model then
        table.insert(info_parts, _("Model:") .. " " .. self.metadata.model)
    end
    if self.metadata.formatted_date then
        table.insert(info_parts, _("Date:") .. " " .. self.metadata.formatted_date)
    elseif self.metadata.timestamp then
        table.insert(info_parts, _("Date:") .. " " .. os.date("%Y-%m-%d", self.metadata.timestamp))
    end
    local cache_info_text = table.concat(info_parts, ". ") .. "."

    -- Wrap on_delete to also close the browser since the cache is gone
    local on_delete_fullview
    if self.on_delete then
        local self_ref = self
        on_delete_fullview = function()
            self_ref.on_delete()
            if self_ref.menu then
                UIManager:close(self_ref.menu)
            end
        end
    end

    -- Overlay on top of the menu — closing the viewer returns to the browser
    UIManager:show(ChatGPTViewer:new{
        title = title,
        text = cache_info_text .. "\n\n" .. markdown,
        _cache_content = markdown,
        simple_view = true,
        cache_metadata = self.metadata.cache_metadata,
        cache_type_name = "X-Ray",
        on_delete = on_delete_fullview,
        configuration = self.metadata.configuration,
    })
end

--- Show options menu (hamburger button)
function XrayBrowser:showOptions()
    local self_ref = self
    local buttons = {}

    -- Delete option
    if self.on_delete then
        table.insert(buttons, {{
            text = _("Delete X-Ray"),
            callback = function()
                if self_ref.options_dialog then
                    UIManager:close(self_ref.options_dialog)
                    self_ref.options_dialog = nil
                end

                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Delete this X-Ray? This cannot be undone."),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        self_ref.on_delete()
                        if self_ref.menu then
                            UIManager:close(self_ref.menu)
                        end
                    end,
                })
            end,
        }})
    end

    -- Update/Redo options (adapted per cache type)
    if self.on_update then
        local cached_dec = self.metadata.progress_decimal or 0
        if self.metadata.full_document then
            -- Full-document cache: redo maintains full-document semantics
            local redo_callback = self.on_update_full or self.on_update
            table.insert(buttons, {{
                text = _("Redo X-Ray (entire document)"),
                callback = function()
                    if self_ref.options_dialog then
                        UIManager:close(self_ref.options_dialog)
                        self_ref.options_dialog = nil
                    end
                    if self_ref.menu then
                        UIManager:close(self_ref.menu)
                    end
                    redo_callback()
                end,
            }})
        elseif cached_dec >= 0.995 then
            -- Partial at 100%: redo to 100% (maintains progress semantics)
            table.insert(buttons, {{
                text = _("Redo X-Ray (to 100%)"),
                callback = function()
                    if self_ref.options_dialog then
                        UIManager:close(self_ref.options_dialog)
                        self_ref.options_dialog = nil
                    end
                    if self_ref.menu then
                        UIManager:close(self_ref.menu)
                    end
                    if self_ref.on_update_to_100 then
                        self_ref.on_update_to_100()
                    else
                        self_ref.on_update()
                    end
                end,
            }})
        else
            -- Partial < 100%: Update/Redo to current + Update to 100%
            local update_text
            local current_dec
            if self.ui then
                local ContextExtractor = require("koassistant_context_extractor")
                local extractor = ContextExtractor:new(self.ui)
                local current = extractor:getReadingProgress()
                current_dec = current.decimal
                if current.decimal > cached_dec + 0.01 then
                    update_text = T(_("Update X-Ray (to %1)"), current.formatted)
                else
                    update_text = T(_("Redo X-Ray (to %1)"), current.formatted)
                end
            end
            if not update_text then
                update_text = _("Redo X-Ray")
            end

            table.insert(buttons, {{
                text = update_text,
                callback = function()
                    if self_ref.options_dialog then
                        UIManager:close(self_ref.options_dialog)
                        self_ref.options_dialog = nil
                    end
                    if self_ref.menu then
                        UIManager:close(self_ref.menu)
                    end
                    self_ref.on_update()
                end,
            }})

            -- "Update to 100%": only when reader isn't already near 100%
            if self_ref.on_update_to_100 and (not current_dec or current_dec < 0.995) then
                table.insert(buttons, {{
                    text = _("Update X-Ray (to 100%)"),
                    callback = function()
                        if self_ref.options_dialog then
                            UIManager:close(self_ref.options_dialog)
                            self_ref.options_dialog = nil
                        end
                        if self_ref.menu then
                            UIManager:close(self_ref.menu)
                        end
                        self_ref.on_update_to_100()
                    end,
                }})
            end
        end
    end

    -- Info
    local info_parts = {}
    if self.metadata.model then
        table.insert(info_parts, _("Model:") .. " " .. self.metadata.model)
    end
    if self.metadata.progress then
        local progress_label = self.metadata.progress
        if self.metadata.previous_progress then
            progress_label = progress_label .. " (" .. _("updated from") .. " " .. self.metadata.previous_progress .. ")"
        end
        table.insert(info_parts, _("Progress:") .. " " .. progress_label)
    end
    if self.metadata.formatted_date then
        table.insert(info_parts, _("Date:") .. " " .. self.metadata.formatted_date)
    elseif self.metadata.timestamp then
        table.insert(info_parts, _("Date:") .. " " .. os.date("%Y-%m-%d %H:%M", self.metadata.timestamp))
    end
    local type_label = XrayParser.isFiction(self.xray_data) and _("Fiction") or _("Non-Fiction")
    table.insert(info_parts, _("Type:") .. " " .. type_label)
    if self.metadata.source_label then
        table.insert(info_parts, _("Source:") .. " " .. self.metadata.source_label)
    end

    if #info_parts > 0 then
        table.insert(buttons, {{
            text = _("Info"),
            callback = function()
                if self_ref.options_dialog then
                    UIManager:close(self_ref.options_dialog)
                    self_ref.options_dialog = nil
                end
                UIManager:show(InfoMessage:new{
                    text = table.concat(info_parts, "\n"),
                })
            end,
        }})
    end

    -- Open Book (when viewing from file browser without the book open)
    if (not self.ui or not self.ui.document) and self.metadata.book_file then
        table.insert(buttons, {{
            text = _("Open Book"),
            callback = function()
                if self_ref.options_dialog then
                    UIManager:close(self_ref.options_dialog)
                    self_ref.options_dialog = nil
                end
                self_ref:_openBookFile()
            end,
        }})
    end

    table.insert(buttons, {{
        text = _("Close"),
        callback = function()
            if self_ref.options_dialog then
                UIManager:close(self_ref.options_dialog)
                self_ref.options_dialog = nil
            end
        end,
    }})

    if self.options_dialog then
        UIManager:close(self.options_dialog)
    end
    self.options_dialog = ButtonDialog:new{
        buttons = buttons,
    }
    UIManager:show(self.options_dialog)
end

--- Open the book file in Reader mode (closing the browser)
function XrayBrowser:_openBookFile()
    local book_file = self.metadata and self.metadata.book_file
    if not book_file then return end
    if self.menu then
        UIManager:close(self.menu)
    end
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(book_file)
end

--- Show popup explaining a feature requires the book to be open in Reader mode
function XrayBrowser:_showReaderRequired()
    local self_ref = self
    if self.metadata and self.metadata.book_file then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("This feature requires the book to be open in Reader mode.\n\nOpen the book now?"),
            ok_text = _("Open Book"),
            ok_callback = function()
                self_ref:_openBookFile()
            end,
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("This feature requires the book to be open in Reader mode."),
        })
    end
end

return XrayBrowser
