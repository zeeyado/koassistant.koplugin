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
local function getAllChapterBoundaries(ui, target_depth)
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
        local is_unread = entry.page > current_page
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
local function getAllPageRangeChapters(ui)
    local total_pages = ui.document.info.number_of_pages or 0
    local current_page = getCurrentPage(ui)
    local chunk = math.max(20, math.floor(total_pages * 0.05))
    local chapters = {}
    local start = 1
    while start <= total_pages do
        local end_page = math.min(start + chunk - 1, total_pages)
        local is_unread = start > current_page
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
--- @param max_chars number Optional cap (default 100000)
--- @return string text
local function extractChapterText(ui, chapter, max_chars)
    max_chars = max_chars or 100000
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
--- @return string chapter_text The extracted text, or empty string
--- @return string chapter_title The chapter title, or empty string
--- @return table|nil toc_info TOC metadata for depth selector
local function getCurrentChapterText(ui, target_depth)
    if not ui or not ui.document then return "", "", nil end

    local total_pages = ui.document.info and ui.document.info.number_of_pages or 0
    if total_pages == 0 then return "", "", nil end

    local chapter, toc_info = getChapterBoundaries(ui, target_depth)
    if not chapter then
        chapter, toc_info = getPageRangeChapter(ui)
    end
    if not chapter then return "", "", nil end

    local text = extractChapterText(ui, chapter)
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
        if orig_onCloseWidget then
            return orig_onCloseWidget(menu_self)
        end
    end
    UIManager:show(self.menu)
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
                        or captured_cat.key == "reader_engagement" then
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

    -- Chapter / whole-book analysis (only when book is open)
    if self.ui and self.ui.document then
        table.insert(items, {
            text = Constants.getEmojiText("📑", _("Mentions (This Chapter)"), enable_emoji),
            callback = function()
                self_ref:showChapterAnalysis()
            end,
        })
        table.insert(items, {
            text = Constants.getEmojiText("📊", _("Mentions (From Beginning)"), enable_emoji),
            callback = function()
                self_ref:showWholeBookAnalysis()
            end,
        })
    end

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

    -- "Chapter Appearances" button (entity-like categories when book is open)
    if self.ui and self.ui.document and not DISTRIBUTION_EXCLUDED[category_key] then
        local dist_item_name = XrayParser.getItemName(item, category_key)
        table.insert(buttons_rows, {{
            text = _("Chapter Appearances"),
            callback = function()
                if viewer then viewer:onClose() end
                self_ref:showItemDistribution(item, category_key, dist_item_name)
            end,
        }})
    end

    -- "Add Search Term" button (searchable categories with known book file)
    if not DISTRIBUTION_EXCLUDED[category_key] and self.metadata.book_file then
        table.insert(buttons_rows, {{
            text = _("Add Search Term"),
            callback = function()
                if viewer then viewer:onClose() end
                self_ref:addUserAlias(item, category_key, title, source)
            end,
            hold_callback = function()
                if viewer then viewer:onClose() end
                self_ref:manageUserAliases(item, category_key, title, source)
            end,
        }})
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
--- @param item table The item data
--- @param category_key string The category key
--- @param item_title string Display title for refreshing detail view
--- @param source table|nil Navigation source for back-button chain
function XrayBrowser:addUserAlias(item, category_key, item_title, source)
    local ActionCache = require("koassistant_action_cache")
    local item_name = XrayParser.getItemName(item, category_key)
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
                    end,
                },
                {
                    text = _("Add"),
                    is_enter_default = true,
                    callback = function()
                        local new_alias = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if not new_alias or new_alias:match("^%s*$") then return end
                        new_alias = new_alias:match("^%s*(.-)%s*$")  -- trim

                        -- Load existing user aliases
                        local all_aliases = ActionCache.getUserAliases(self_ref.metadata.book_file)
                        local item_aliases = all_aliases[item_name] or {}

                        -- Check for duplicates (case-insensitive)
                        for _idx, alias in ipairs(item_aliases) do
                            if alias:lower() == new_alias:lower() then
                                UIManager:show(InfoMessage:new{
                                    text = _("This search term already exists."),
                                    timeout = 2,
                                })
                                return
                            end
                        end

                        -- Save
                        table.insert(item_aliases, new_alias)
                        all_aliases[item_name] = item_aliases
                        ActionCache.setUserAliases(self_ref.metadata.book_file, all_aliases)

                        -- Update in-memory item aliases
                        if type(item.aliases) ~= "table" then
                            item.aliases = item.aliases and { item.aliases } or {}
                        end
                        table.insert(item.aliases, new_alias)

                        -- Clear distribution cache for this item (forces recount)
                        if self_ref._dist_cache then
                            self_ref._dist_cache[tostring(item)] = nil
                        end

                        -- Refresh detail view to show new alias
                        self_ref:showItemDetail(item, category_key, item_title, source)
                        UIManager:show(Notification:new{
                            text = T(_("Added \"%1\""), new_alias),
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

--- Show dialog to manage (remove) custom search terms for an item
--- @param item table The item data
--- @param category_key string The category key
--- @param item_title string Display title for refreshing detail view
--- @param source table|nil Navigation source for back-button chain
function XrayBrowser:manageUserAliases(item, category_key, item_title, source)
    local ActionCache = require("koassistant_action_cache")
    local item_name = XrayParser.getItemName(item, category_key)
    local all_aliases = ActionCache.getUserAliases(self.metadata.book_file)
    local user_aliases = all_aliases[item_name] or {}

    if #user_aliases == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No custom search terms for this item."),
            timeout = 2,
        })
        return
    end

    local self_ref = self
    local buttons = {}

    for _idx, alias in ipairs(user_aliases) do
        local captured_alias = alias
        table.insert(buttons, {{
            text = T(_("Remove \"%1\""), alias),
            callback = function()
                UIManager:close(self_ref._manage_dialog)
                self_ref._manage_dialog = nil

                -- Remove from storage
                local fresh_aliases = ActionCache.getUserAliases(self_ref.metadata.book_file)
                local item_list = fresh_aliases[item_name] or {}
                for i = #item_list, 1, -1 do
                    if item_list[i]:lower() == captured_alias:lower() then
                        table.remove(item_list, i)
                    end
                end
                fresh_aliases[item_name] = item_list
                ActionCache.setUserAliases(self_ref.metadata.book_file, fresh_aliases)

                -- Remove from in-memory item
                if type(item.aliases) == "table" then
                    for i = #item.aliases, 1, -1 do
                        if item.aliases[i]:lower() == captured_alias:lower() then
                            table.remove(item.aliases, i)
                        end
                    end
                end

                -- Clear distribution cache (forces recount)
                if self_ref._dist_cache then
                    self_ref._dist_cache[tostring(item)] = nil
                end

                -- Refresh detail view
                self_ref:showItemDetail(item, category_key, item_title, source)
                UIManager:show(Notification:new{
                    text = T(_("Removed \"%1\""), captured_alias),
                })
            end,
        }})
    end

    table.insert(buttons, {{
        text = _("Close"),
        callback = function()
            UIManager:close(self_ref._manage_dialog)
            self_ref._manage_dialog = nil
        end,
    }})

    self._manage_dialog = ButtonDialog:new{
        title = T(_("Custom search terms for \"%1\""), item_name),
        buttons = buttons,
    }
    UIManager:show(self._manage_dialog)
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

--- Show depth picker for TOC level selection
--- @param toc_info table TOC metadata from getChapterBoundaries
function XrayBrowser:showDepthPicker(toc_info)
    local self_ref = self
    local buttons = {}
    for depth = 1, toc_info.max_depth do
        local title = toc_info.depth_titles and toc_info.depth_titles[depth]
        local label
        if title and title ~= "" then
            label = T(_("Level %1: %2"), depth, title)
        else
            label = T(_("Level %1"), depth)
        end
        table.insert(buttons, {{
            text = label,
            callback = function()
                UIManager:close(self_ref._depth_dialog)
                -- Navigate back to remove current results
                self_ref:navigateBack()
                -- Re-run with new depth
                self_ref:showChapterAnalysis(depth)
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Cancel"),
        callback = function()
            UIManager:close(self_ref._depth_dialog)
        end,
    }})
    self._depth_dialog = ButtonDialog:new{
        title = _("Select TOC depth"),
        buttons = buttons,
    }
    UIManager:show(self._depth_dialog)
end

--- Show all X-Ray items appearing in the current chapter
--- @param target_depth number|nil TOC depth filter
function XrayBrowser:showChapterAnalysis(target_depth)
    if not self.ui or not self.ui.document then
        UIManager:show(InfoMessage:new{
            text = _("No book open."),
            timeout = 3,
        })
        return
    end

    -- Show processing notification
    UIManager:show(Notification:new{
        text = _("Analyzing chapter…"),
    })

    -- Schedule the actual work to let the notification render
    local self_ref = self
    UIManager:scheduleIn(0.2, function()
        local chapter_text, chapter_title, toc_info = getCurrentChapterText(self_ref.ui, target_depth)

        if not chapter_text or chapter_text == "" then
            local msg = self_ref.ui.document.info.has_pages
                and _("Could not extract chapter text. PDF text extraction may not be available for this document.")
                or _("Could not extract chapter text.")
            UIManager:show(InfoMessage:new{
                text = msg,
                timeout = 5,
            })
            return
        end

        local found = XrayParser.findItemsInChapter(self_ref.xray_data, chapter_text)

        if #found == 0 then
            local msg = chapter_title ~= "" and
                T(_("No X-Ray items found in \"%1\"."), chapter_title) or
                _("No X-Ray items found in current chapter.")
            UIManager:show(InfoMessage:new{
                text = msg,
                timeout = 4,
            })
            return
        end

        -- Build menu items
        local items = {}

        -- TOC depth selector (when multiple depths available)
        if toc_info and toc_info.has_toc and toc_info.max_depth > 1 then
            local current_depth = target_depth or toc_info.max_depth
            local depth_title = toc_info.depth_titles and toc_info.depth_titles[current_depth]
            local depth_label
            if depth_title and depth_title ~= "" then
                depth_label = T(_("Level %1: %2 \u{25BE}"), current_depth, depth_title)
            else
                depth_label = T(_("TOC Level %1 \u{25BE}"), current_depth)
            end
            table.insert(items, {
                text = depth_label,
                mandatory = T(_("%1 levels"), toc_info.max_depth),
                mandatory_dim = true,
                bold = true,
                callback = function()
                    self_ref:showDepthPicker(toc_info)
                end,
                separator = true,
            })
        end

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
        if chapter_title ~= "" then
            title = T(_("%1 — %2 mentions"), chapter_title, #found)
        else
            title = T(_("This Chapter — %1 mentions"), #found)
        end

        self_ref:navigateForward(title, items)
    end)
end

--- Show all X-Ray items found across the whole book (page 1 to current page)
function XrayBrowser:showWholeBookAnalysis()
    if not self.ui or not self.ui.document then
        UIManager:show(InfoMessage:new{
            text = _("No book open."),
            timeout = 3,
        })
        return
    end

    -- Show processing notification
    UIManager:show(Notification:new{
        text = _("Analyzing book…"),
    })

    local self_ref = self
    UIManager:scheduleIn(0.2, function()
        local total_pages = self_ref.ui.document.info.number_of_pages or 0
        if total_pages == 0 then
            UIManager:show(InfoMessage:new{
                text = _("Could not determine book length."),
                timeout = 3,
            })
            return
        end

        local current_page = getCurrentPage(self_ref.ui)
        local chapter = {
            start_page = 1,
            end_page = current_page,
        }

        local text = extractChapterText(self_ref.ui, chapter, 500000)

        if not text or text == "" then
            local msg = self_ref.ui.document.info.has_pages
                and _("Could not extract book text. PDF text extraction may not be available for this document.")
                or _("Could not extract book text.")
            UIManager:show(InfoMessage:new{
                text = msg,
                timeout = 5,
            })
            return
        end

        local found = XrayParser.findItemsInChapter(self_ref.xray_data, text)

        if #found == 0 then
            UIManager:show(InfoMessage:new{
                text = _("No X-Ray items found in book text."),
                timeout = 4,
            })
            return
        end

        -- Build menu items
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

        local title = T(_("From Beginning — %1 mentions"), #found)
        self_ref:navigateForward(title, items)
    end)
end

--- Show all X-Ray items in a specific chapter (given boundaries)
--- Called from distribution view when tapping a chapter.
--- Unlike showChapterAnalysis(), takes arbitrary chapter boundaries
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
        local text = extractChapterText(self_ref.ui, chapter)

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
                            local text = extractChapterText(self_ref.ui, captured_chapter, 500000)
                            local ch_count = 0
                            if text and text ~= "" then
                                ch_count = XrayParser.countItemOccurrences(item, text:lower())
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
                            text = _("This chapter is ahead of your reading position and may contain spoilers.\n\nReveal mentions?"),
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
                        -- Close browser, navigate to chapter, search for item
                        local captured_ui = self_ref.ui
                        UIManager:close(self_ref.menu)
                        captured_ui:handleEvent(Event:new("GotoPage", captured_chapter.start_page))
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
                            UIManager:scheduleIn(0.2, function()
                                if #alias_terms > 0 then
                                    -- Escape ECMAScript regex special chars in each term
                                    local function esc(s)
                                        return s:gsub("([%.%+%*%?%[%]%^%$%(%)%{%}%|\\])", "\\%1")
                                    end
                                    local pattern = esc(search_name)
                                    for _idx2, a in ipairs(alias_terms) do
                                        pattern = pattern .. "|" .. esc(a)
                                    end
                                    -- Set search state so input dialog reflects the regex pattern
                                    captured_ui.search.last_search_text = pattern
                                    captured_ui.search.use_regex = true
                                    captured_ui.search.case_insensitive = true
                                    captured_ui.search:onShowSearchDialog(pattern, 0, true, true)
                                else
                                    captured_ui.search:searchCallback(0, search_name)
                                end
                            end)
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
                            local text = extractChapterText(self_ref.ui, chapters[j], 500000)
                            local ch_count = 0
                            if text and text ~= "" then
                                ch_count = XrayParser.countItemOccurrences(item, text:lower())
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
        -- Get all chapters
        local chapters, _toc_info = getAllChapterBoundaries(self_ref.ui)
        if not chapters then
            chapters, _toc_info = getAllPageRangeChapters(self_ref.ui)
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
                local text = extractChapterText(self_ref.ui, chapter, 500000)
                local count = 0
                if text and text ~= "" then
                    count = XrayParser.countItemOccurrences(item, text:lower())
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

return XrayBrowser
