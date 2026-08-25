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

-- Forward declaration for mutual reference
local dismissSearchReturnButton

-- ============== Right-column (mandatory) fitting ==============
-- KOReader's MenuItem lays the mandatory column out FIRST and gives the name
-- whatever is left, so a long right-hand label starves the row's actual
-- subject. Round 28 (#90 device report on the carried list: "you barely have
-- any space for the main item"): one shared fitter for every X-Ray list.
--   * MEASURED, not counted — the old per-list math divided by the width of a
--     latin "a", which is ~half a CJK glyph, and compared it against a BYTE
--     length (3 bytes per CJK char), so both sides were wrong in opposite
--     directions and the byte-slice could cut mid-codepoint (mojibake).
--   * A hard share cap keeps the subject readable even when the name is short
--     — without it a two-character name still yields the row to a long title.
local MANDATORY_MAX_SHARE = 0.45   -- right column never claims more than this
local ELLIPSIS = "…"

-- How many connection buttons an entity page draws before the rest move behind
-- an overflow row (schema key features.xray_connection_buttons overrides).
-- ButtonTable takes whatever height it needs and TextViewer gives the text
-- whatever is left, with no floor — so an entity with dozens of connections
-- squeezed its own description down to a couple of lines (issue #90).
local CONNECTION_BUTTONS_DEFAULT = 9

--- Truncate `secondary` (UTF-8 safe) so it fits beside `name` in a menu row.
--- @param name string The row's subject (measured, never truncated here —
---   the Menu widget elides it if the remainder is still too small)
--- @param secondary string Candidate right-column text
--- @param opts table { content_width, text_face, mandatory_face, padding,
---   min_chars = floor below which truncation stops, max_share = override }
--- @return string fitted (possibly ellipsized; "" when nothing fits)
local function fitMandatory(name, secondary, opts)
    if type(secondary) ~= "string" or secondary == "" then return "" end
    local TextWidget = require("ui/widget/textwidget")
    local util = require("util")
    local function widthOf(text, face)
        local w = TextWidget:new{ text = text, face = face }
        local size = w:getSize().w
        w:free()
        return size
    end
    local budget = (opts.content_width * (opts.max_share or MANDATORY_MAX_SHARE))
    local name_w = widthOf(name or "", opts.text_face)
    local leftover = opts.content_width - name_w - opts.padding
    -- The right column gets the smaller of "what the name left over" and its
    -- share cap, but never less than the caller's declared minimum
    local avail = math.min(budget, math.max(leftover, 0))
    local chars = util.splitToChars(secondary)
    local min_chars = math.min(opts.min_chars or 5, #chars)
    local min_w = widthOf(table.concat(chars, "", 1, min_chars), opts.mandatory_face)
    if avail < min_w then avail = min_w end
    if widthOf(secondary, opts.mandatory_face) <= avail then return secondary end
    -- Largest prefix that fits with an ellipsis (binary search over CHARS, so
    -- a multi-byte glyph is never split)
    local lo, hi, best = min_chars, #chars, nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local candidate = table.concat(chars, "", 1, mid) .. ELLIPSIS
        if widthOf(candidate, opts.mandatory_face) <= avail then
            best = candidate
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return best or (table.concat(chars, "", 1, min_chars) .. ELLIPSIS)
end

--- Show a floating "Back to X-Ray" button overlay.
--- Appears after a mention row / fallback launch closes the browser and
--- enters the native search session (launchSearchSession).
--- Tap: reopens the X-Ray browser at the distribution view.
--- Hold: dismisses the button without navigating.
--- Uses toast=true so events propagate to widgets below (search dialog stays interactive).
local function showSearchReturnButton(return_state)
    dismissSearchReturnButton()

    -- Lazy requires (avoid top-level to prevent init-order issues)
    local Button = require("ui/widget/button")
    local Size = require("ui/size")

    local margin = Screen:scaleBySize(12)
    local btn = Button:new{
        text = _("← X-Ray"),
        radius = Size.radius.button,
        callback = function()
            -- Dismiss overlay synchronously (safe: just removes current toast from stack)
            dismissSearchReturnButton()
            -- Schedule heavy work for next event loop to avoid modifying
            -- the window stack during UIManager's toast event dispatch phase
            UIManager:nextTick(function()
                -- Close KOReader's search dialog(s) if still open
                local ui = return_state.ui
                if ui and ui.search then
                    if ui.search.input_dialog and UIManager:isWidgetShown(ui.search.input_dialog) then
                        UIManager:close(ui.search.input_dialog)
                    end
                    if ui.search.search_dialog then
                        ui.search.search_dialog:onClose()
                    end
                end
                -- Reopen X-Ray browser via plugin reference
                local plugin = return_state.plugin_ref
                if plugin then
                    local ActionCache = require("koassistant_action_cache")
                    local book_file = ui and ui.document and ui.document.file
                    if book_file then
                        local scope = return_state.scope
                        local cache_key = (scope and scope.cache_key) or "_xray_cache"
                        local cached = ActionCache.get(book_file, cache_key)
                        if cached then
                            -- Set navigate_to so show() auto-navigates to the distribution view
                            XrayBrowser._pending_navigate_to = {
                                category_key = return_state.category_key,
                                item_name = return_state.item_name,
                                open_distribution = true,
                            }
                            -- Chain one level further: reopen the MENTION
                            -- page the user came from (round 4) once the
                            -- distribution is up. Copy — book_file stamping
                            -- must not mutate the shared descriptor
                            if return_state.mentions_state then
                                local pm = {}
                                for k, v in pairs(return_state.mentions_state) do
                                    pm[k] = v
                                end
                                pm.book_file = book_file
                                XrayBrowser._pending_mentions = pm
                            end
                            local name = "X-Ray"
                            if scope and scope.label then
                                name = T(_("Section X-Ray: %1"), scope.label)
                            end
                            plugin:showCacheViewer({
                                name = name,
                                key = cache_key,
                                data = cached,
                            })
                        end
                    end
                end
                -- Restore the reading position captured at jump time (round
                -- 4): returning must never leave the reader at the search
                -- hit — tapping outside to read on is how you KEEP the spot.
                -- AFTER the browser reopen, so the fullscreen menu covers the
                -- book repaint (round 5: no flash of the page underneath);
                -- no marker arg — the target-line marker belongs to jumps TO
                -- a hit, not to going back
                local origin = return_state.origin
                if ui and origin then
                    if origin.xp then
                        ui:handleEvent(Event:new("GotoXPointer", origin.xp))
                    elseif origin.page then
                        ui:handleEvent(Event:new("GotoPage", origin.page))
                    end
                end
            end)
        end,
        hold_callback = function()
            -- Long-press dismisses the button without navigating back
            dismissSearchReturnButton()
        end,
    }

    -- toast = true: UIManager dispatches events to toasts in a separate phase and
    -- always propagates them to widgets below, so this overlay won't block the search dialog.
    btn.toast = true

    -- Position at top-center (avoids keyboard overlap at bottom)
    local btn_width = btn:getSize().w
    local pos_x = math.floor((Screen:getWidth() - btn_width) / 2)
    local pos_y = margin

    XrayBrowser._search_return_overlay = btn
    UIManager:show(btn, "partial", nil, pos_x, pos_y)

    -- Auto-dismiss when the search dialog is closed.
    -- Polls UIManager's widget stack: stays alive while either the search results
    -- dialog (search_dialog) or expanded input dialog (input_dialog) is showing.
    local function pollSearchActive()
        if not XrayBrowser._search_return_overlay then return end -- already dismissed
        local search = return_state.ui and return_state.ui.search
        if not search then
            dismissSearchReturnButton()
            return
        end
        if (search.search_dialog and UIManager:isWidgetShown(search.search_dialog))
                or (search.input_dialog and UIManager:isWidgetShown(search.input_dialog)) then
            UIManager:scheduleIn(0.5, pollSearchActive)
        else
            dismissSearchReturnButton()
        end
    end
    UIManager:scheduleIn(0.5, pollSearchActive)
end

--- Dismiss the floating "Back to X-Ray" button if visible
dismissSearchReturnButton = function()
    if XrayBrowser._search_return_overlay then
        UIManager:close(XrayBrowser._search_return_overlay)
        XrayBrowser._search_return_overlay = nil
    end
end

--- Entity name + aliases as search terms: array of { text, regex } — regex =
--- the Arabic diacritics-tolerant pattern where applicable (EPUB engine
--- only). Shared by the mention list and the native-search launches. The
--- implementation moved to XrayParser (slice 2) so ambient marking shares
--- the exact same term rules.
local collectSearchTerms = XrayParser.collectSearchTerms

--- EPUB regex-OR of every term (so the native search session walks name AND
--- aliases with its own prev/next). nil when a single plain term suffices.
local function buildSearchPattern(terms)
    if #terms == 1 and not terms[1].regex then return nil end
    local function one(term)
        return term.regex
            or term.text:gsub("([%.%+%*%?%[%]%^%$%(%)%{%}%|\\])", "\\%1")
    end
    local pattern = one(terms[1])
    for i = 2, #terms do
        pattern = pattern .. "|" .. one(terms[i])
    end
    return pattern
end

--- Gather every exact-text hit for an entity across the WHOLE document —
--- the one native pass that powers the distribution counts AND the mention
--- lists (slice 4, ref #78): findAllText per term (Arabic regex on EPUB),
--- position-dedup, doc-order sort, PTF bold-match snippet per hit. Spoiler
--- gating is applied at DISPLAY time by the consumers (data in memory is
--- not data shown). Cap: 5000 hits per term (very common terms clip there).
--- Context: 10 words per side (round 9 — the 3-line snippet rows can afford
--- more than the search dialog's default).
--- @return table hits Array of {page?, xp?, display_page, row_text, term, order}
local function gatherMentionHits(ui, terms)
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local is_pages = ui.document.info and ui.document.info.has_pages
    local hits, seen = {}, {}
    for _idx, term in ipairs(terms) do
        local res
        if term.regex and not is_pages then
            -- Arabic terms: diacritics-tolerant regex (EPUB engine only;
            -- 0x0001 = MATCH_ACROSS_TEXT_NODES, stock's regex-type flags)
            res = ui.document:findAllText(term.regex, true, 10, 5000, true, 0x0001)
        else
            -- 0x00FF = stock's default-search flag set — without it crengine
            -- matches nothing across DOM node boundaries and folds no
            -- NBSP/soft-hyphen (the marks round-4 styled-name miss; the
            -- same latent gap sat here under counts + mention lists). The
            -- PDF engine takes 5 args and ignores the extra.
            res = ui.document:findAllText(term.text, true, 10, 5000, false, 0x00FF)
        end
        if res then
            for _idx2, r in ipairs(res) do
                local page, key
                if is_pages then
                    -- Paginated: r.start IS the page number
                    page = r.start
                    local b = r.boxes and r.boxes[1]
                    key = tostring(page) .. "|" .. tostring(b and b.x) .. "|" .. tostring(b and b.y)
                else
                    page = ui.document:getPageFromXPointer(r.start)
                    key = tostring(r.start)
                end
                if page and not seen[key] then
                    seen[key] = true
                    -- Bold-match snippet (readersearch.lua idiom);
                    -- ellipsized both ends — rows are mid-text fragments
                    local text = { TextBoxWidget.PTF_HEADER, "… " }
                    if r.prev_text then
                        table.insert(text, r.prev_text)
                        if not r.prev_text:find("%s$") then
                            table.insert(text, " ")
                        end
                    end
                    table.insert(text, TextBoxWidget.PTF_BOLD_START)
                    table.insert(text, r.matched_word_prefix or "")
                    table.insert(text, r.matched_text or term.text)
                    table.insert(text, r.matched_word_suffix or "")
                    table.insert(text, TextBoxWidget.PTF_BOLD_END)
                    if r.next_text then
                        if not r.next_text:find("^[%s%p]") then
                            table.insert(text, " ")
                        end
                        table.insert(text, r.next_text)
                    end
                    table.insert(text, " …")
                    table.insert(hits, {
                        page = is_pages and page or nil,
                        xp = (not is_pages) and r.start or nil,
                        display_page = page,
                        row_text = table.concat(text),
                        term = term,
                        order = #hits + 1,
                    })
                end
            end
        end
    end
    -- Document order: by page, insertion order breaking ties (table.sort
    -- is not stable; same-page hits from different terms must not shuffle)
    table.sort(hits, function(a, b)
        if a.display_page ~= b.display_page then
            return a.display_page < b.display_page
        end
        return a.order < b.order
    end)
    return hits
end

--- Open KOReader's native search session for the term at the CURRENT
--- position, then float the "Back to X-Ray" button. The built-in search owns
--- highlighting and prev/next — no custom overlay (maintainer 2026-08-13).
local function launchSearchSession(ui, term, use_regex, return_info)
    UIManager:scheduleIn(0.2, function()
        if use_regex then
            -- The session runs ENTIRELY on onShowSearchDialog's args (its
            -- prev/next closures capture them) — write NOTHING onto the
            -- search module. Setting last_search_text leaked our pipes
            -- pattern into the user's regular search-input prefill, and a
            -- synthesized current_search_type table read as "no type
            -- selected" there (the type checkboxes compare by TABLE
            -- IDENTITY), so a later manual search ran the pattern literally
            -- and found nothing (device 2026-08-13).
            -- KOReader master changed onShowSearchDialog's 3rd arg from a
            -- boolean `regex` to a `search_type` table ({flags, regex}); the
            -- master handler does `search_type.regex`, so a bare boolean
            -- crashes ("attempt to index a boolean"). Detect the new API via
            -- default_search_type and pass KOReader's OWN regex entry (0x0001
            -- fallback matches its stock flags).
            local regex_arg = true
            if type(ui.search.default_search_type) == "table" then
                regex_arg = nil
                for _idx, st in ipairs(ui.search.search_types or {}) do
                    if st.regex then
                        regex_arg = st
                        break
                    end
                end
                regex_arg = regex_arg or { flags = 0x0001, regex = true }
            else
                -- Legacy boolean API read the module field, not the arg
                ui.search.use_regex = true
            end
            ui.search:onShowSearchDialog(term, 0, regex_arg, true)
        else
            ui.search:searchCallback(0, term)
        end
        -- Show floating "Back to X-Ray" button after search starts
        UIManager:scheduleIn(0.3, function()
            showSearchReturnButton(return_info)
        end)
    end)
end

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

--- Get ALL page-range chunks for books without usable TOC
--- Chunks past the spoiler gate are marked unread
--- @param ui table KOReader UI instance
--- @param gate_page number|nil Spoiler gate (from _spoilerGate; nil = no gating)
--- @return table chapters Array of {title, start_page, end_page, depth, is_current, unread}
--- @return table toc_info {has_toc = false, max_depth = 0}
local function getAllPageRangeChapters(ui, gate_page)
    local total_pages = ui.document.info.number_of_pages or 0
    local current_page = getCurrentPage(ui)
    local chunk = math.max(20, math.floor(total_pages * 0.05))
    local chapters = {}
    local start = 1
    while start <= total_pages do
        local end_page = math.min(start + chunk - 1, total_pages)
        local is_unread = (gate_page and start > gate_page) or false
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
--- Returns every entry for use in the hierarchical chapter picker and the
--- Chapter Appearances tree (slice 4).
--- @param ui table KOReader UI instance
--- @param gate_page number|nil Spoiler gate (from _spoilerGate; nil = no gating)
--- @return table|nil entries Array of {title, start_page, end_page, depth, is_current, unread}
--- @return number max_depth Maximum TOC depth found
local function getHierarchicalChapters(ui, gate_page, scope)
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
        local is_unread = (not scope and gate_page and entry.page > gate_page) or false
        -- Section scope: a chapter is out_of_scope if it doesn't overlap with the scope
        -- Overlap check: parent chapters that contain the scope stay in-scope (start before, end after)
        local is_out_of_scope = false
        if scope then
            is_out_of_scope = entry.page > scope.end_page or end_page < scope.start_page
        end
        local is_current = false
        if scope then
            is_current = current_page >= entry.page and current_page <= end_page
                and current_page >= scope.start_page and current_page <= scope.end_page
        else
            is_current = not is_unread and current_page >= entry.page and current_page <= end_page
        end
        table.insert(entries, {
            title = entry.title or "",
            start_page = entry.page,
            end_page = end_page,
            depth = d,
            is_current = is_current,
            unread = is_unread,
            out_of_scope = is_out_of_scope,
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
        -- No page cap: the char budget below is the sole bound. A silent
        -- +50-page cap made "no mentions" a lie on long monograph chapters.
        local end_page = chapter.end_page
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
--- 1 word + short hold → auto dictionary, 1 word + long hold or 2+ words → selection popup
--- @param text string Selected text
--- @param hold_duration userdata|nil Hold duration from TextBoxWidget
--- @param opts table Options: ui, plugin, viewer (TextViewer for highlight clearing),
---        book_file/book_title (the X-Ray's SOURCE book — ui is nil for cross-book viewing)
local function handleTextSelection(text, hold_duration, opts)
    local ui = opts.ui
    local ChatGPTViewer = require("koassistant_chatgptviewer")

    -- Count words: 1 word → auto dictionary, 2+ → popup
    local word_count = 0
    if text then
        for _w in text:gmatch("%S+") do
            word_count = word_count + 1
            if word_count > 1 then break end
        end
    end

    local function clear_highlight()
        local viewer = opts.viewer
        -- KOReader renamed TextViewer.scroll_text_w to scroll_widget (2026-07)
        local sw = viewer and (viewer.scroll_widget or viewer.scroll_text_w)
        if sw and sw.text_widget then
            local tw = sw.text_widget
            if tw.clearHighlight and tw:clearHighlight() then
                tw:redrawHighlight()
            end
        end
    end

    if word_count == 1 and not ChatGPTViewer.isLongHold(hold_duration) then
        -- Single word + short hold: auto dictionary lookup (fast path)
        if ui and ui.dictionary then
            ui.dictionary._koassistant_non_reader_lookup = true
            -- Carry the X-Ray's SOURCE book so a bypass / dict-popup X-Ray
            -- lookup targets it, not whatever the reader has open
            ui.dictionary._koassistant_lookup_book = opts.book_file or nil
            ui.dictionary:onLookupWord(text)
            clear_highlight()
            return
        end
    end

    -- 2+ words, or single word + long hold: show selection popup
    -- Target the X-Ray's SOURCE book (metadata.book_file) — ui is deliberately nil
    -- when viewing another book's X-Ray via the artifact browser, and the notebook
    -- belongs to the X-Ray's book either way (getPath resolves from disk)
    local doc_path = opts.book_file or (ui and ui.document and ui.document.file)
    local append_to_notebook
    if doc_path then
        append_to_notebook = function(sel_text)
            ChatGPTViewer.appendSnippetToNotebook(doc_path, sel_text, {
                book_title = opts.book_title
                    or (ui and ui.doc_props
                        and (ui.doc_props.display_title or ui.doc_props.title)),
            })
        end
    end
    ChatGPTViewer.buildTextSelectionPopup(text, {
        ui = ui,
        plugin = opts.plugin,
        configuration = opts.plugin and opts.plugin.configuration,
        document_path = doc_path,
        append_to_notebook = append_to_notebook,
        clear_highlight = clear_highlight,
    })
end

-- Emoji mappings for category keys (used when enable_emoji_icons is on)
-- Short category labels for chapter analysis display
-- The Chapter Appearances tree renders denser than the rest of the browser
-- (round 10, maintainer: "way too much" line height): more rows per page,
-- with the row font following KOReader's own perpage→font mapping — the
-- stock-TOC pairing. Rides the nav-stack display protocol, so every other
-- level keeps the browser's constructed metrics.
local TREE_PERPAGE = 20

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
    -- Round 27: the carried list labels every stub's category, and full
    -- inclusion means these keys reach it too (they were already missing here
    -- for chapter analysis)
    key_concepts = _("Concepts"),
    technical_terms = _("Terms"),
    foundations = _("Basis"),
    methodology = _("Method"),
    findings = _("Findings"),
    referenced_works = _("Works"),
    figures_data = _("Data"),
}

local CATEGORY_EMOJIS = {
    characters = "👥", key_figures = "👥",
    locations = "🌍", core_concepts = "💡",
    themes = "💭", arguments = "⚖️",
    lexicon = "📖", terminology = "📖",
    timeline = "📅", argument_development = "📅",
    key_concepts = "💡", foundations = "📐",
    methodology = "🔬", findings = "📊",
    referenced_works = "📚", technical_terms = "📖",
    figures_data = "📈",
    reader_engagement = "📌",
    current_state = "📍", current_position = "📍",
    conclusion = "🏁",
}

-- Categories excluded from per-item distribution and highlight matching
-- Mirrors TEXT_MATCH_EXCLUDED in parser: singletons + event-based categories
-- whose "names" are descriptive phrases, not searchable entity names
local DISTRIBUTION_EXCLUDED = {
    current_state = true,
    current_position = true,
    reader_engagement = true,
    conclusion = true,
    arguments = true,
    argument_development = true,
    timeline = true,
    findings = true,
    figures_data = true,
}

--- Show the top-level X-Ray category menu
--- @param xray_data table Parsed JSON structure
--- @param metadata table { title, progress, model, timestamp, book_file, enable_emoji }
--- @param ui table|nil KOReader UI instance (nil when book not open)
--- @param on_delete function|nil Callback to delete this cache
function XrayBrowser:show(xray_data, metadata, ui, on_delete)
    require("koassistant_logger").dbg("KOAssistant XrayBrowser: open",
        (metadata and metadata.book_file) or "?",
        "scope=", tostring((metadata and metadata.scope and metadata.scope.label) or "main"),
        "checkpoint=", tostring(metadata and metadata.checkpoint or false))
    self.xray_data = xray_data
    self.metadata = metadata
    self.ui = ui
    self.on_delete = on_delete
    self.nav_stack = {}
    self._mentions_spoiler_warned = nil
    -- Singleton hygiene (round 26): self IS the module table, so every per-view
    -- field must die with the previous view or it leaks into the NEXT book —
    -- a stale location sent group jumps to the wrong book's entity, and a stale
    -- _dormant_archived skipped the next book's first pre-op ring archive.
    self.location = nil
    self._detail_viewer = nil
    self._dist_cache = nil
    self._text_cache = nil
    self._scope_reveal_warned = nil
    self._dormant_archived = nil
    -- Q6: browsing sessions default to parent-reveal on the entity X; the
    -- direct-entry openers (lookup exact-match, card tap-through) set this
    -- AFTER show, and the entity close_callback consumes it
    self._direct_entry_exit = nil
    -- Widgets to close when launching book text search (e.g., dictionary popup, cross-section results)
    self._cleanup_widgets = metadata._cleanup_widgets

    -- Spoiler gating for text-matching features (Mentions, Chapter
    -- Appearances, the pickers) is resolved per view by _spoilerGate()
    -- (F2, slice 4): posture-routed (research/finished/book/global), and
    -- under protection strictly the READING POSITION — X-Ray coverage no
    -- longer reveals beyond what the reader has read.

    -- Section X-Ray scope: replaces spoiler gating (the scope is consent)
    self.scope = metadata.scope  -- nil for main X-Ray
    if self.scope then
        self.scope_start = self.scope.start_page
        self.scope_end = self.scope.end_page
    end

    -- Build update callback from plugin reference (works from all call sites)
    self.on_update = nil
    self.on_extend_rebuild = nil
    -- Section X-Rays: no update/redo callbacks (complete-only)
    -- Archived-version views (metadata.checkpoint): read-only, no update either
    if self.scope or metadata.checkpoint then
        -- No-op
    elseif metadata.plugin and ui and ui.document then
        local plugin_ref = metadata.plugin
        self.on_update = function()
            local action = plugin_ref.action_service:getAction("book", "xray")
            if action then
                if plugin_ref:_checkRequirements(action) then return end
                plugin_ref:_executeBookLevelActionDirect(action, "xray")
            end
        end
        -- Device round 2026-08-05 parity: every redo/whole-book path routes
        -- through the SAME dual-mode form as the popup (extend /
        -- rebuild-from-scratch / checkpoints / background delivery) instead of
        -- firing a raw foreground update
        self.on_extend_rebuild = function(force_rebuild)
            local action = plugin_ref.action_service:getAction("book", "xray")
            if action then
                if plugin_ref:_checkRequirements(action) then return end
                plugin_ref:_showXrayCreationChooser(action, "xray", function()
                    plugin_ref:_executeBookLevelActionDirect(action, "xray")
                end, nil, force_rebuild)
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

    -- Warn if reading position is outside active hidden flow
    if ui and ui.document and ui.document.hasHiddenFlows
            and ui.document:hasHiddenFlows() then
        local current_page = getCurrentPage(ui)
        if ui.document:getPageFlow(current_page) ~= 0 then
            UIManager:show(Notification:new{
                text = _("Position is outside the active hidden flow"),
            })
        end
    end

    local items = self:buildCategoryItems()
    local title = self:buildMainTitle()
    self.current_title = title

    -- Gray one-liner naming the book (item 46 follow-up): vital orientation
    -- when hopping between group volumes' X-Rays
    local menu_subtitle = self.metadata.title
    if menu_subtitle and menu_subtitle ~= ""
        and self.metadata.book_author and self.metadata.book_author ~= "" then
        menu_subtitle = menu_subtitle .. " · " .. self.metadata.book_author
    end

    local self_ref = self
    self.menu = Menu:new{
        title = title,
        subtitle = menu_subtitle,
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
    -- Row metrics the menu was constructed with: a display-passing level
    -- that doesn't state its own drops back to THESE (not the Menu class
    -- defaults — items_per_page nil means the user's global setting, which
    -- is not the browser's constructed look). Only the compact appearances
    -- tree overrides them.
    self._base_metrics = {
        items_per_page = self.menu.items_per_page,
        items_font_size = self.menu.items_font_size,
        items_mandatory_font_size = self.menu.items_mandatory_font_size,
    }
    -- TOC-style expand/collapse for the appearances tree (readertoc idiom):
    -- a tap on the state-arrow side of a row with a state button toggles the
    -- node instead of selecting it; everything else keeps Menu's default
    -- dispatch (item callbacks).
    local orig_onMenuSelect = self.menu.onMenuSelect
    self.menu.onMenuSelect = function(menu_self, sel_item, pos)
        if sel_item and sel_item.state and pos and pos.x then
            local BD = require("ui/bidi")
            local toggle
            if BD.mirroredUILayout() then
                toggle = pos.x > 0.7
            else
                toggle = pos.x < 0.3
            end
            if toggle and sel_item.state.callback then
                sel_item.state.callback(sel_item.index)
                return true
            end
        end
        return orig_onMenuSelect(menu_self, sel_item, pos)
    end
    -- Hook into onCloseWidget for cleanup (only fires when widget is actually removed)
    local orig_onCloseWidget = self.menu.onCloseWidget
    self.menu.onCloseWidget = function(menu_self)
        self_ref.menu = nil
        self_ref.nav_stack = {}
        self_ref._dist_cache = nil
        self_ref._text_cache = nil
        self_ref.on_update = nil
        dismissSearchReturnButton()
        if orig_onCloseWidget then
            return orig_onCloseWidget(menu_self)
        end
    end
    -- Book page level-up (book page round, 2026-08-09): live views sit one
    -- level BELOW the book page, so the ◀ arrow stays active at root — seeding
    -- paths is what enables it (Menu: #paths > 0) — and navigateBack at root
    -- opens the page instead of closing. Archived-version views keep plain
    -- close (read-only inspection reached from a versions list).
    if not metadata.checkpoint and metadata.book_file and metadata.plugin then
        self._level_up = true
        table.insert(self.menu.paths, true)
        -- Menu:init already evaluated the arrow with empty paths — re-evaluate,
        -- or the arrow stays dead until the first forward/back navigation
        self.menu:updatePageInfo()
    else
        self._level_up = nil
    end
    UIManager:show(self.menu)

    -- Auto-navigate to saved position (from file browser reopen or search return flow)
    -- Run synchronously (no scheduleIn) so all switchItemTable calls batch into one repaint.
    if XrayBrowser._pending_navigate_to then
        local navigate_to = XrayBrowser._pending_navigate_to
        XrayBrowser._pending_navigate_to = nil
        -- Book guard (round 25): the descriptor is a module-level static and is
        -- only consumed by a browser that actually opens — an unparseable cache
        -- leaves it stranded, where the NEXT book's browser would consume it.
        -- Producers that stamp book_file opt into the check.
        if navigate_to.book_file and navigate_to.book_file ~= self.metadata.book_file then
            navigate_to = nil
        end
        if navigate_to and navigate_to.fallback then
            -- Group jump: land as close to the reader's previous position as
            -- this book allows, then fall back one level at a time
            self:_applyPendingLocation(navigate_to)
            navigate_to = nil
        end
        local target_items = navigate_to and self.xray_data[navigate_to.category_key]
        if target_items then
            for _idx, target_item in ipairs(target_items) do
                if XrayParser.getItemName(target_item, navigate_to.category_key) == navigate_to.item_name then
                    if navigate_to.open_distribution then
                        -- Push category items onto nav stack first (search return flow)
                        -- so back from distribution goes to category items, not main categories
                        local categories = XrayParser.getCategories(self_ref.xray_data)
                        for _idx2, cat in ipairs(categories) do
                            if cat.key == navigate_to.category_key then
                                self_ref:showCategoryItems(cat)
                                break
                            end
                        end
                        self_ref:showItemDistribution(target_item, navigate_to.category_key, navigate_to.item_name)
                    else
                        -- Go to item detail (file browser reopen flow)
                        self_ref:showItemDetail(target_item, navigate_to.category_key, navigate_to.item_name)
                    end
                    break
                end
            end
        end
    end
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
    if lower ~= "" then
        -- Normalize Unicode characters that break plain text matching.
        -- Use string.char() for Lua 5.1 compatibility (no \xNN escapes).
        local SOFT_HYPHEN = string.char(0xC2, 0xAD)   -- U+00AD: invisible hyphenation hints
        local NBSP        = string.char(0xC2, 0xA0)   -- U+00A0: non-breaking space
        local ZWSP        = string.char(0xE2, 0x80, 0x8B) -- U+200B: zero-width space
        lower = lower:gsub(SOFT_HYPHEN, ""):gsub(NBSP, " "):gsub(ZWSP, "")
        -- Normalize Arabic diacritics for fuzzy matching (no-op on non-Arabic text)
        lower = XrayParser.normalizeArabic(lower)
    end
    self._text_cache[key] = { raw = raw, lower = lower }
    return raw, lower
end

--- Build the main title for the browser
--- @return string title
function XrayBrowser:buildMainTitle()
    if self.scope then
        local scope_title = T(_("X-Ray § %1"), self.scope.label)
        if self.metadata.timestamp then
            local rel = Constants.formatRelativeTime(self.metadata.timestamp)
            if rel ~= "" then
                scope_title = scope_title .. " · " .. rel
            end
        end
        return scope_title
    end
    local title = self.metadata.checkpoint and _("X-Ray Version") or "X-Ray"
    if self.metadata.progress then
        title = title .. " (" .. self.metadata.progress .. ")"
    end
    if self.metadata.timestamp then
        local rel = Constants.formatRelativeTime(self.metadata.timestamp)
        if rel ~= "" then
            title = title .. " · " .. rel
        end
    end
    return title
end

--- Build item table for the top-level category menu
--- @return table items Menu item table
--- Carried-list wording follows the group kind: "earlier" implies a reading
--- order, which only series groups have. Project/plain folds still fill the
--- ledger (fan-in / manual merges), so their label says "related books" —
--- the wording the entity index already uses model-side. (2026-08-09)
--- @param book_file string|nil
--- @param n number|nil Count for the titled form; nil = bare row label
--- @return string
local function dormantListTitle(book_file, n)
    local BookGroups = require("koassistant_book_groups")
    local series = false
    for _idx, g in ipairs(BookGroups.groupsFor(book_file or "") or {}) do
        if BookGroups.kindOf(g) == BookGroups.KIND_SERIES then
            series = true
            break
        end
    end
    if n then
        return series and T(_("Carried from earlier books (%1)"), n)
            or T(_("Carried from group (%1)"), n)
    end
    return series and _("Carried from earlier books") or _("Carried from group")
end

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
            -- Don't show count for singleton categories (always 1)
            if cat.key ~= "current_state" and cat.key ~= "current_position"
                and cat.key ~= "reader_engagement" and cat.key ~= "conclusion" then
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

    -- Carried from earlier books (series-identity round, 2026-08-06): the
    -- dormant ledger made visible — entities carried from the group's earlier
    -- volumes that have not appeared in this book yet. Main live views only,
    -- same rationale as the dedup row: the manual actions write the live main.
    -- Count what the list will actually SHOW (round 27) — a restored older
    -- version's theme stubs are filtered out of both
    local dormant_n = (not self.scope and not self.metadata.checkpoint
        and self.metadata.plugin and self.metadata.book_file)
        and #self:_dormantRows() or 0
    if dormant_n > 0 then
        table.insert(items, {
            -- 📥 not 📚 (2026-08-09): 📚 is Library Chat's icon; the ledger is
            -- an inbox of entities brought IN from other books
            text = Constants.getEmojiText("📥", dormantListTitle(self.metadata.book_file), enable_emoji),
            mandatory = tostring(dormant_n),
            callback = function()
                self_ref:showDormantList()
            end,
        })
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
        text = Constants.getEmojiText("🔍", _("Search X-Ray"), enable_emoji),
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

    -- X-Ray chats (device round 2026-08-15): chats launched from entity
    -- pages save as ordinary book chats and were hard to find again — count
    -- the launch-tagged ones and open the book's chat list narrowed to them
    -- (chats saved before the tag existed stay in the full Chat History).
    -- One sidecar read; main live views only, the browsing home.
    if not self.scope and not self.metadata.checkpoint
            and self.metadata.plugin and self.metadata.book_file then
        local xchat_n = 0
        local ok_list, chats = pcall(function()
            local ChatHistoryManager = require("koassistant_chat_history_manager")
            return ChatHistoryManager:new():getChatsUnified(self.ui, self.metadata.book_file)
        end)
        if ok_list and type(chats) == "table" then
            for _idx, c in ipairs(chats) do
                if c.launched_from == "xray_chat" then xchat_n = xchat_n + 1 end
            end
        end
        if xchat_n > 0 then
            table.insert(items, {
                text = Constants.getEmojiText("💬", _("X-Ray chats"), enable_emoji),
                mandatory = tostring(xchat_n),
                callback = function()
                    self_ref.metadata.plugin:showChatHistoryForFile(self_ref.metadata.book_file, {
                        close_on_up = true,
                        filter_launched_from = "xray_chat",
                        list_title = self_ref.metadata.title
                            and T(_("X-Ray chats: %1"), self_ref.metadata.title)
                            or _("X-Ray chats"),
                    })
                end,
            })
        end
    end

    -- Other artifacts for this book (if any)
    local artifacts = self:_getAvailableArtifacts()
    if #artifacts > 0 then
        items[#items].separator = true
        if #artifacts == 1 then
            local art = artifacts[1]
            local label = art.name
            -- Shared meta (A4 parity): "Recap (6%, today)", percent always
            if not (art.is_pinned_group or art.is_section_group
                    or art.is_section_xray_group or art.is_wiki_group) then
                local meta = Constants.formatArtifactMeta(art.data)
                if meta then label = label .. " (" .. meta .. ")" end
            end
            table.insert(items, {
                text = Constants.getEmojiText("📋", label, enable_emoji),
                callback = function()
                    -- Fetch fresh in case new artifacts were created while browser is open
                    local fresh = self_ref:_getAvailableArtifacts()
                    if #fresh == 1 then
                        self_ref:_openArtifact(fresh[1])
                    elseif #fresh > 1 then
                        self_ref:_showOtherArtifacts(fresh)
                    end
                end,
            })
        else
            table.insert(items, {
                text = Constants.getEmojiText("📋", _("Other Artifacts") .. "…", enable_emoji),
                mandatory = tostring(#artifacts),
                callback = function()
                    -- Fetch fresh in case new artifacts were created while browser is open
                    local fresh = self_ref:_getAvailableArtifacts()
                    self_ref:_showOtherArtifacts(fresh)
                end,
            })
        end
    end

    return items
end

--- Display order for the carried list: the same reading order the category
--- menu uses (people, places, vocabulary, ideas), then name. Insertion order
--- is write order — seeds, folds and rebuilds each append — which is why a
--- late-linked character surfaced as "a sudden extra cast" at the bottom
--- (device round 27).
local DORMANT_CATEGORY_RANK = {
    characters = 1, key_figures = 1,
    locations = 2,
    lexicon = 3, terminology = 3, technical_terms = 3,
    core_concepts = 4, key_concepts = 4,
    referenced_works = 5,
    -- The analysis categories carry too (round 27 full inclusion) and sit
    -- after the identities: they are reading material, not entries waiting to
    -- wake, so they must not push the cast down the page
    themes = 6, arguments = 6, foundations = 6,
    methodology = 7, findings = 7, figures_data = 7,
}

--- The carried ledger as DISPLAY rows: everything it holds, in category then
--- name order, each keeping its raw ledger index for the edit ops. Nothing is
--- hidden (round 27 full inclusion) — insertion order is WRITE order, which is
--- the only reason this exists: a stub added by a later fold or a rebuild
--- carry landed at the bottom regardless of category ("a sudden extra cast").
--- @return table rows Array of { idx, stub, rank }
function XrayBrowser:_dormantRows()
    local ledger = self.xray_data and self.xray_data[XrayParser.DORMANT_KEY]
    local rows = {}
    if type(ledger) ~= "table" then return rows end
    for i, stub in ipairs(ledger) do
        if type(stub) == "table" and type(stub.name) == "string" and stub.name ~= "" then
            rows[#rows + 1] = { idx = i, stub = stub,
                rank = DORMANT_CATEGORY_RANK[stub.category or ""] or 9 }
        end
    end
    table.sort(rows, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.stub.name ~= b.stub.name then return a.stub.name < b.stub.name end
        return a.idx < b.idx
    end)
    return rows
end

--- Menu items for the carried-entity list. Round 26 (device report: "the popup
--- is very bad design"): the ledger renders as an ordinary paginated browser
--- page like every other entity list, not as a stack of full-width buttons.
--- @return table items
function XrayBrowser:_buildDormantItems()
    local self_ref = self
    local items = {}
    local rows = self:_dormantRows()
    -- Round 28 (#90 device report: "you barely have any space for the main
    -- item"): this list was the ONE X-Ray list that passed its right column
    -- through raw, so a long (CJK) source title swallowed the row and the
    -- carried entity's NAME — the thing you are reading the list for — got
    -- elided. Same measured fitter as the category lists now; the category tag
    -- is protected as the minimum, since it survives being the only thing left.
    local Font = require("ui/font")
    local Size = require("ui/size")
    local fit_opts = {
        content_width = Screen:getWidth() - 2 * (Size.padding.fullscreen or 0),
        text_face = Font:getFace("smallinfofont", 18),
        mandatory_face = Font:getFace("infont", 14),
        padding = Screen:scaleBySize(10),
        min_chars = 4,
    }
    for i, r in ipairs(rows) do
        local captured_i, captured, display_i = r.idx, r.stub, i
        local short_cat = CHAPTER_CATEGORY_SHORT[captured.category]
        local src = (type(captured.source) == "string" and captured.source) or ""
        -- The source title is what overflows, so fit THAT and keep the tag whole
        local tag = short_cat and (short_cat .. " · ") or ""
        local fitted_src = src ~= "" and fitMandatory(
            (captured.name or "") .. tag, src, fit_opts) or ""
        table.insert(items, {
            text = captured.name,
            mandatory = tag .. fitted_src,
            mandatory_dim = true,
            callback = function()
                -- ◀/▶ walk the DISPLAYED rows (filtered + sorted); the ledger
                -- index rides along for the edit ops, which address the raw
                -- ledger
                self_ref:showDormantDetail(captured_i, captured,
                    { rows = rows, index = display_i })
            end,
        })
    end
    return items
end

--- Carried-entities list (series-identity round; Menu page since round 26):
--- every dormant ledger stub — name, category and source book — one tap from
--- the main category menu. Reading is the primary use ("who might return?");
--- the per-stub detail offers the manual actions.
function XrayBrowser:showDormantList()
    local items = self:_buildDormantItems()
    if #items == 0 then return end
    -- A carried stub is not a live entity in THIS book, so there is no honest
    -- "→ Group" target from these pages
    self.location = nil
    self:navigateForward(dormantListTitle(self.metadata.book_file, #items), items)
end

--- Repaint the carried list in place after an edit (the root-only refresh in
--- _commitDormantOp cannot see this page). Pops back out when the last stub
--- leaves, so the reader never stares at an empty list.
function XrayBrowser:_refreshDormantPage()
    if not self.menu then return end
    local items = self:_buildDormantItems()
    if #items == 0 then
        self:navigateBack()
        return
    end
    self.current_title = dormantListTitle(self.metadata.book_file, #items)
    self.menu:switchItemTable(self.current_title, items, -1)
end

--- One carried entity: its full history, and the manual actions — link to an
--- existing entry (reader-asserted identity, the zero-token fix for naming
--- drift the model missed), promote to a visible entry, or remove.
--- Round 26 (device report: "the character info is very long and you have to
--- scroll a small thing at the bottom"): a scrollable TextViewer with a real
--- button row, exactly like showItemDetail — the body is text, the actions
--- are buttons, and neither fights the other for space.
--- @param nav_context table|nil { stubs, index } for ◀/▶ within the list
function XrayBrowser:showDormantDetail(stub_idx, stub, nav_context)
    local self_ref = self
    local parts = { stub.name, "" }
    if type(stub.aliases) == "table" and #stub.aliases > 0 then
        parts[#parts + 1] = _("Also known as:") .. " " .. table.concat(stub.aliases, ", ")
    end
    if type(stub.source) == "string" and stub.source ~= "" then
        parts[#parts + 1] = T(_("Carried from: %1"), stub.source)
    end
    parts[#parts + 1] = ""
    parts[#parts + 1] = _("Not seen in this book yet. It wakes on its own when an update or merge meets it.")
    if type(stub.description) == "string" and stub.description ~= "" then
        parts[#parts + 1] = ""
        parts[#parts + 1] = stub.description
    end
    if type(stub.background) == "table" and #stub.background > 0 then
        parts[#parts + 1] = ""
        parts[#parts + 1] = _("From earlier books:")
        for _idx, b in ipairs(stub.background) do
            if type(b) == "table" and type(b.text) == "string" and b.source then
                parts[#parts + 1] = T(_("%1: %2"), b.source, b.text)
            end
        end
    end

    local viewer
    local function afterClose(fn)
        return function()
            if viewer then viewer:onClose() end
            fn()
        end
    end
    local buttons_rows = {
        {
            {
                text = _("This is an existing entry…"),
                callback = afterClose(function()
                    self_ref:showDormantLinkPicker(stub_idx, stub)
                end),
            },
        },
        {
            {
                text = _("Add as its own entry"),
                callback = afterClose(function()
                    -- Round 27 (maintainer: "could easily be done by accident
                    -- and there is no way back"): confirm, and name the way
                    -- back so it is not a one-way door
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Add \"%1\" to this book's X-Ray as its own entry?\nIt stops being listed as carried. Its entry page offers \"Move back to carried list\"."), stub.name),
                        ok_text = _("Add"),
                        ok_callback = function()
                            if self_ref:_commitDormantOp(
                                function(data) return XrayParser.promoteStub(data, stub_idx, stub.name) end,
                                T(_("\"%1\" added to the X-Ray."), stub.name)) then
                                self_ref:_refreshDormantPage()
                            end
                        end,
                    })
                end),
            },
            {
                text = _("Remove"),
                callback = afterClose(function()
                    if self_ref:_commitDormantOp(
                        function(data) return XrayParser.removeStub(data, stub_idx, stub.name) ~= nil end,
                        T(_("\"%1\" removed from the carried list."), stub.name)) then
                        self_ref:_refreshDormantPage()
                    end
                end),
            },
        },
    }
    -- Prev/next within the carried list, mirroring showItemDetail's nav row
    local rows = nav_context and nav_context.rows
    if rows and #rows > 1 then
        local idx = nav_context.index
        local function jump(i)
            self_ref:showDormantDetail(rows[i].idx, rows[i].stub, { rows = rows, index = i })
        end
        table.insert(buttons_rows, {
            {
                text = "◀",
                callback = afterClose(function()
                    jump(idx > 1 and idx - 1 or #rows)
                end),
            },
            {
                text = "▶",
                callback = afterClose(function()
                    jump(idx < #rows and idx + 1 or 1)
                end),
            },
        })
    end

    local display_title = stub.name
    if rows and #rows > 1 then
        display_title = T("(%1/%2) %3", nav_context.index, #rows, display_title)
    end
    viewer = TextViewer:new{
        title = display_title,
        text = table.concat(parts, "\n"),
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        buttons_table = buttons_rows,
    }
    UIManager:show(viewer)
end

--- Same-category picker for the manual link: "this carried entity IS that
--- existing entry". Round 26: a browser Menu page (a real Cast list runs well
--- past what a button stack can show), with a name filter above 20 entries.
--- @param filter string|nil Case-insensitive substring filter
function XrayBrowser:showDormantLinkPicker(stub_idx, stub, filter)
    local self_ref = self
    local cat_key = stub.category
    local cat_label, cat_items
    for _idx, cat in ipairs(XrayParser.getCategories(self.xray_data)) do
        if cat.key == cat_key then
            cat_label, cat_items = cat.label, cat.items
            break
        end
    end
    if type(cat_items) ~= "table" or #cat_items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("This book's X-Ray has no entries in that category yet."),
            timeout = 4,
        })
        return
    end
    local items = {}
    if #cat_items >= 20 then
        table.insert(items, {
            text = filter and T(_("Filter: \"%1\" (tap to change)"), filter) or _("Find by name…"),
            bold = true,
            separator = true,
            callback = function()
                local input
                input = InputDialog:new{
                    title = _("Find by name"),
                    input = filter or "",
                    buttons = {{
                        { text = _("Cancel"), callback = function() UIManager:close(input) end },
                        {
                            text = _("Filter"),
                            is_enter_default = true,
                            callback = function()
                                local q = input:getInputText()
                                UIManager:close(input)
                                self_ref:navigateBack()
                                self_ref:showDormantLinkPicker(stub_idx, stub,
                                    (q ~= "" and q) or nil)
                            end,
                        },
                    }},
                }
                UIManager:show(input)
                input:onShowKeyboard()
            end,
        })
    end
    local needle = filter and filter:lower() or nil
    for _idx, item in ipairs(cat_items) do
        local name = XrayParser.getItemName(item, cat_key)
        if type(name) == "string" and name ~= ""
            and (not needle or name:lower():find(needle, 1, true)) then
            local captured = name
            table.insert(items, {
                text = captured,
                mandatory = (type(item.aliases) == "table" and item.aliases[1]) or nil,
                mandatory_dim = true,
                callback = function()
                    if self_ref:_commitDormantOp(
                        function(data)
                            return XrayParser.wakeStubInto(data, stub_idx, stub.name, cat_key, captured)
                        end,
                        T(_("Folded \"%1\" into \"%2\" — its carried history now shows there."),
                            stub.name, captured)) then
                        -- Pop the picker; the list underneath re-reads the ledger
                        self_ref:navigateBack()
                        self_ref:_refreshDormantPage()
                    end
                end,
            })
        end
    end
    self.location = nil
    self:navigateForward(T(_("%1 is which %2 entry?"), stub.name,
        cat_label or _("existing")), items)
end

--- Land a group jump as close to the reader's previous position as this book
--- allows (round 25 — "open the other X-Ray where you are now, or one level up
--- if that entry doesn't exist"). Ladder, most specific first:
---   1. the same entity, matched by name OR alias in ANY category (volumes
---      rename and re-classify recurring figures) → its detail, with the
---      owning category pushed underneath so Back lands there;
---   2. the entity carried but not yet appeared here → its carried-entity
---      detail, with the carried list pushed underneath (the ledger IS this
---      book's honest answer, and it says so);
---   3. the same category → its item list;
---   4. neither → the root, untouched.
--- @param navigate_to table { category_key, item_name, item_aliases }
function XrayBrowser:_applyPendingLocation(navigate_to)
    local names = {}
    if navigate_to.item_name then names[#names + 1] = navigate_to.item_name end
    if type(navigate_to.item_aliases) == "table" then
        for _idx, a in ipairs(navigate_to.item_aliases) do names[#names + 1] = a end
    end
    local categories = XrayParser.getCategories(self.xray_data)
    local function categoryByKey(key)
        for _idx, cat in ipairs(categories) do
            if cat.key == key then return cat end
        end
        return nil
    end
    if #names > 0 then
        local item, cat_key, idx = XrayParser.findByIdentity(
            self.xray_data, names, navigate_to.category_key)
        if item then
            local cat = categoryByKey(cat_key)
            if cat then self:showCategoryItems(cat) end
            self:showItemDetail(item, cat_key, XrayParser.getItemName(item, cat_key), nil, {
                items = cat and cat.items,
                index = idx,
                category_key = cat_key,
                category_label = cat and cat.label,
            })
            return
        end
        local stub, stub_idx = XrayParser.findDormantByIdentity(self.xray_data, names)
        if stub then
            -- Push the carried list underneath so Back lands there, exactly as
            -- the live-entity branch above pushes its category (round 26).
            -- The ◀/▶ context is the DISPLAY order, so locate this stub in it.
            self:showDormantList()
            local rows = self:_dormantRows()
            local display_i
            for i, r in ipairs(rows) do
                if r.idx == stub_idx then display_i = i break end
            end
            self:showDormantDetail(stub_idx, stub,
                display_i and { rows = rows, index = display_i } or nil)
            return
        end
    end
    local cat = navigate_to.category_key and categoryByKey(navigate_to.category_key)
    if cat and type(cat.items) == "table" and #cat.items > 0 then
        if cat.key == "current_state" or cat.key == "current_position"
            or cat.key == "reader_engagement" or cat.key == "conclusion" then
            self:showItemDetail(cat.items[1], cat.key, cat.label)
        else
            self:showCategoryItems(cat)
        end
    end
end

--- Re-read the live main X-Ray from disk into the OPEN browser and repaint
--- (round 25, device report): a merge run from outside the browser — the
--- post-create fold especially, which fires while the reader is looking at the
--- X-Ray it just built — rewrites the artifact underneath a view that holds a
--- parsed snapshot from open time. Every merge entry point that OPENED the
--- browser retires it (the T11 rule); this is the equivalent for a view the
--- merge did not open: refresh in place rather than close it out from under
--- the reader. Root-level only (a deeper view's item tables reference the old
--- data), section/archived views never touch live truth. Safe no-op when no
--- browser is open or another book's is.
--- @param file string Book path whose live X-Ray changed
--- @return boolean refreshed
function XrayBrowser:reloadLiveMain(file)
    require("koassistant_logger").dbg("KOAssistant XrayBrowser: reloadLiveMain", file)
    if not (self.menu and self.metadata and self.metadata.book_file == file) then return false end
    if self.scope or self.metadata.checkpoint then return false end
    local ActionCache = require("koassistant_action_cache")
    local entry = ActionCache.getXrayCache(file)
    if not (entry and entry.result and XrayParser.isJSON(entry.result)) then return false end
    local data = XrayParser.parse(entry.result)
    if not data or data.error then return false end
    local user_aliases = ActionCache.getUserAliases(file)
    if next(user_aliases) then
        XrayParser.mergeUserAliases(data, user_aliases)
    end
    self.xray_data = data
    -- The reload usually follows a merge — the fold ledger may have grown, and
    -- Info reads metadata, not the disk entry
    self.metadata.merged_from = entry.merged_from
    self.metadata.merged_from_books = entry.merged_from_books
    if #self.nav_stack == 0 then
        self.menu:switchItemTable(self:buildMainTitle(), self:buildCategoryItems(), -1)
    end
    return true
end

--- One dormant-ledger edit against DISK truth (dedup's commit pattern):
--- Returns true only when the write landed (callers repaint on that).
--- fresh parse → apply → re-encode → commitXray (pre-op version ring-archived
--- once per browser session) → refresh the open root menu.
function XrayBrowser:_commitDormantOp(apply_fn, success_text)
    local ActionCache = require("koassistant_action_cache")
    local WriteBack = require("koassistant_artifact_writeback")
    local file = self.metadata.book_file
    local entry = ActionCache.getXrayCache(file)
    if not (entry and entry.result) then
        UIManager:show(InfoMessage:new{ text = _("No main X-Ray found on disk."), timeout = 4 })
        return false
    end
    local data = XrayParser.parse(entry.result)
    if not data or data.error then
        UIManager:show(InfoMessage:new{ text = _("The stored X-Ray could not be parsed."), timeout = 4 })
        return false
    end
    if not apply_fn(data) then
        UIManager:show(InfoMessage:new{
            text = _("The carried list changed on disk. Reopen it and try again."),
            timeout = 4,
        })
        return false
    end
    local json = require("json")
    local okj, cache_json = pcall(json.encode, data, { pretty = true, indent = true })
    if not okj or type(cache_json) ~= "string" then
        UIManager:show(InfoMessage:new{ text = _("Failed to serialize the updated X-Ray."), timeout = 4 })
        return false
    end
    local meta = {}
    for k, v in pairs(entry) do meta[k] = v end
    meta.result = nil
    meta.timestamp = nil
    meta.progress_decimal = nil
    local plugin_ref = self.metadata.plugin
    local ok = WriteBack.commitXray(file, cache_json, entry.progress_decimal or 0, meta, {
        prev = entry,
        limit = self._dormant_archived and 0 or nil,
        features = (self.metadata.configuration and self.metadata.configuration.features) or {},
        refresh_fn = function()
            if plugin_ref then
                plugin_ref._file_dialog_row_cache = { file = nil, rows = nil }
            end
        end,
    })
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("Could not save the X-Ray."), timeout = 4 })
        return false
    end
    self._dormant_archived = true
    self.xray_data = data
    UIManager:show(Notification:new{ text = success_text })
    -- Root repaint: the carried count changed, possibly a category count too.
    -- Deeper pages (the carried list) repaint via _refreshDormantPage — the
    -- caller does it, since only it knows which page is on screen.
    if self.menu and #self.nav_stack == 0 then
        self.menu:switchItemTable(self:buildMainTitle(), self:buildCategoryItems(), -1)
    end
    return true
end

--- Navigate forward: push current state and switch to new items
--- @param title string New menu title
--- @param items table New menu items
function XrayBrowser:navigateForward(title, items, focus_idx, display)
    if not self.menu then return end

    -- Save current state (incl. display params, so a level that flips the
    -- menu to multiline — the mention list — restores cleanly on back)
    table.insert(self.nav_stack, {
        title = self.current_title,
        items = self.menu.item_table,
        location = self.location,
        display = {
            single_line = self.menu.single_line,
            multilines_forced = self.menu.multilines_forced,
            items_max_lines = self.menu.items_max_lines,
            state_w = self.menu.state_w,
            with_dots = self.menu.with_dots,
            align_baselines = self.menu.align_baselines,
            line_color = self.menu.line_color,
            items_per_page = self.menu.items_per_page,
            items_font_size = self.menu.items_font_size,
            items_mandatory_font_size = self.menu.items_mandatory_font_size,
        },
    })
    self.current_title = title
    if display then
        -- Protocol: a display-passing level states everything it needs;
        -- unstated fields drop to the Menu class defaults (nil clears the
        -- instance field), so one level's styling never leaks into the next.
        -- Exception: the row METRICS drop to the browser's constructed
        -- values instead — Menu's own fallback for a nil items_per_page is
        -- the user's global setting, not our look. switchItemTable with a
        -- new table always re-runs _recalculateDimen, which re-reads them.
        local base = self._base_metrics or {}
        self.menu.single_line = display.single_line
        self.menu.multilines_forced = display.multilines_forced
        self.menu.items_max_lines = display.items_max_lines
        self.menu.state_w = display.state_w
        self.menu.with_dots = display.with_dots
        self.menu.align_baselines = display.align_baselines
        self.menu.line_color = display.line_color
        self.menu.items_per_page = display.items_per_page or base.items_per_page
        self.menu.items_font_size = display.items_font_size or base.items_font_size
        self.menu.items_mandatory_font_size = display.items_mandatory_font_size
            or base.items_mandatory_font_size
        -- Metrics must be LIVE before switchItemTable computes the focus
        -- page: getPageNumber divides by self.perpage, which only updates
        -- inside updateItems' recalc — AFTER the page pick. With the stale
        -- divisor the result then clamps to the new page count (device
        -- round 8: the appearances tree opened on its LAST page, current
        -- chapter off-screen).
        if self.menu._recalculateDimen then
            self.menu:_recalculateDimen()
        end
    end

    -- Add to paths so back arrow becomes enabled via updatePageInfo
    table.insert(self.menu.paths, true)
    self:_switchMenuItems(title, items, focus_idx)
end

--- switchItemTable with a fresh multiline page map. Menu:switchItemTable
--- computes the focus page from `page_items` BEFORE recalculating them —
--- on a menu born single-line the map is nil (device crash: menu.lua
--- getPageNumber "bad argument #1 to 'ipairs'" entering the appearances
--- tree with a focus index), and on a re-entered multiline level it is the
--- OUTGOING table's stale map. Pre-build it for the new table whenever the
--- items_max_lines machinery is active and a focus target is given.
function XrayBrowser:_switchMenuItems(title, items, focus_idx)
    if focus_idx and self.menu.items_max_lines and self.menu.setupItemHeights then
        self.menu.item_table = items
        self.menu:setupItemHeights()
    end
    self.menu:switchItemTable(title, items, focus_idx)
end

--- Navigate back: pop state and restore, or close if at root
function XrayBrowser:navigateBack()
    if not self.menu then return end

    if #self.nav_stack == 0 then
        -- At root level — up to the book page when seeded (book page round;
        -- live views sit one level below it), else close
        local meta = self.metadata
        local ui = self.ui
        UIManager:close(self.menu)
        if self._level_up and meta then
            require("koassistant_book_page").show({
                file = meta.book_file,
                plugin = meta.plugin,
                ui = ui,
                title = meta.title,
                author = meta.book_author,
                enable_emoji = meta.enable_emoji,
            })
        end
        return
    end

    local prev = table.remove(self.nav_stack)
    self.current_title = prev.title
    -- The group jump follows the reader back out (round 25)
    self.location = prev.location
    -- Restore the display params saved at push time (multiline levels,
    -- the appearances tree's state column / dots / hidden dividers)
    if prev.display then
        self.menu.single_line = prev.display.single_line
        self.menu.multilines_forced = prev.display.multilines_forced
        self.menu.items_max_lines = prev.display.items_max_lines
        self.menu.state_w = prev.display.state_w
        self.menu.with_dots = prev.display.with_dots
        self.menu.align_baselines = prev.display.align_baselines
        self.menu.line_color = prev.display.line_color
        self.menu.items_per_page = prev.display.items_per_page
        self.menu.items_font_size = prev.display.items_font_size
        self.menu.items_mandatory_font_size = prev.display.items_mandatory_font_size
    end

    -- Remove from paths so back arrow disables when we reach root
    table.remove(self.menu.paths)
    if #self.nav_stack == 0 then
        self.location = nil
        -- Back at root — rebuild to reflect any new artifacts (wiki, pins)
        local fresh_items = self:buildCategoryItems()
        self.menu:switchItemTable(self:buildMainTitle(), fresh_items, -1)
    else
        self.menu:switchItemTable(prev.title, prev.items)
    end

    -- Reopen item detail TextViewer if distribution was entered from one
    if prev.reopen_detail then
        local d = prev.reopen_detail
        local nav_ctx = d.nav_context
        -- Reconstruct nav_context if not provided (e.g. search return flow)
        if not nav_ctx and self.xray_data and self.xray_data[d.category_key] then
            local cat_items = self.xray_data[d.category_key]
            for idx, cat_item in ipairs(cat_items) do
                if cat_item == d.item then
                    nav_ctx = { items = cat_items, index = idx, category_key = d.category_key }
                    break
                end
            end
        end
        self:showItemDetail(d.item, d.category_key, d.title, d.source, nav_ctx)
    end
end

--- Show items within a category (navigates forward)
--- @param category table {key, label, items}
function XrayBrowser:showCategoryItems(category)
    local Font = require("ui/font")
    local Size = require("ui/size")

    local items = {}
    local self_ref = self

    -- Widths + faces for the shared mandatory fitter (measured per candidate,
    -- so no reference-glyph estimate is needed any more)
    local content_width = Screen:getWidth() - 2 * (Size.padding.fullscreen or 0)
    local text_face = Font:getFace("smallinfofont", 18)
    local mandatory_face = Font:getFace("infont", 14)
    local padding = Screen:scaleBySize(10)

    -- Event-based categories: guarantee minimum mandatory (chapter label) width
    local is_event_category = category.key == "timeline" or category.key == "argument_development"

    for _idx, item in ipairs(category.items) do
        local name = XrayParser.getItemName(item, category.key)
        local secondary = XrayParser.getItemSecondary(item, category.key)

        -- Section X-Rays: strip scope label prefix from chapter references.
        -- e.g., "Part 1, Chapter 3" → "Chapter 3" (scope label is already in the title)
        -- AI text is free-form, so we try multiple strategies:
        -- 1. Exact scope label prefix ("88. Al-Ghashiyah — سورة الغاشية" → match)
        -- 2. Scope label without leading numbering ("Al-Ghashiyah — سورة الغاشية" → match)
        -- 3. First significant name from scope label ("Al-Ghashiyah" → match)
        if secondary ~= "" and self.scope and self.scope.label then
            local lower_secondary = secondary:lower()
            -- Build candidate prefixes from scope label, most specific first
            local candidates = { self.scope.label }
            -- Strip leading number + punctuation: "88. Al-Ghashiyah..." → "Al-Ghashiyah..."
            local without_number = self.scope.label:gsub("^%d+[%.%)%s:%-–—]+%s*", "")
            if without_number ~= self.scope.label and without_number ~= "" then
                table.insert(candidates, without_number)
            end
            -- First segment before separator (—, -, :): "Al-Ghashiyah — سورة..." → "Al-Ghashiyah"
            for _ci, candidate in ipairs({self.scope.label, without_number}) do
                local first_seg = candidate:match("^(.-)%s*[—–:]+%s")
                if first_seg and first_seg ~= "" and first_seg ~= candidate then
                    table.insert(candidates, first_seg)
                end
            end
            for _ci, candidate in ipairs(candidates) do
                local lower_candidate = candidate:lower()
                if lower_secondary:sub(1, #lower_candidate) == lower_candidate then
                    local rest = secondary:sub(#lower_candidate + 1)
                    rest = rest:gsub("^[%s,;:%-–—>]+%s*", "")
                    if rest ~= "" then
                        secondary = rest
                        break
                    end
                end
            end
        end

        -- Fit mandatory (role / chapter label) beside the name. Round 28: the
        -- shared measured, UTF-8-safe fitter replaces the byte-counting math
        -- (which mis-sized every non-latin label and could cut mid-glyph).
        -- Event categories keep a higher minimum so chapter labels aren't
        -- squashed to 2-3 chars.
        if secondary ~= "" then
            secondary = fitMandatory(name, secondary, {
                content_width = content_width,
                text_face = text_face,
                mandatory_face = mandatory_face,
                padding = padding,
                min_chars = is_event_category and 15 or 5,
                -- Event rows are ABOUT their chapter label — let it take more
                max_share = is_event_category and 0.5 or nil,
            })
        end

        local captured_item = item
        local captured_idx = _idx
        table.insert(items, {
            text = name,
            mandatory = secondary,
            mandatory_dim = true,
            callback = function()
                self_ref:showItemDetail(captured_item, category.key, name, nil, {
                    items = category.items,
                    index = captured_idx,
                    category_key = category.key,
                    category_label = category.label,
                })
            end,
        })
    end

    -- Where the reader is now, in machine-readable form (round 25): the group
    -- row carries this to the next book's X-Ray so the jump lands in the same
    -- place instead of at its root
    self.location = { category_key = category.key, category_label = category.label }

    local title = category.label .. " (" .. #category.items .. ")"
    self:navigateForward(title, items)
end

--- Every connection of one entity as a paged list (the overflow behind the
--- entity page's button cap). Uses the browser's own nav stack, so back
--- returns to the category the reader came from, and each row opens the target
--- with the full carousel in place.
--- @param conn_entries table Resolved, target-deduped connection entries
--- @param source table|nil Back-navigation chain from the entity page
--- @param owner_title string Name of the entity these belong to
function XrayBrowser:_showConnectionList(conn_entries, source, owner_title)
    if not self.menu then return end
    local self_ref = self
    local items = {}
    for idx, entry in ipairs(conn_entries) do
        local captured_idx = idx
        -- Show what the model actually wrote, wrapped, rather than the name
        -- with the relationship truncated into a grey column: the relationship
        -- IS the content here, and there was nowhere else to read it (device
        -- 2026-08-18 — "the kid — watches him with apparent intere…").
        local row_text = entry.raw or entry.button_text
        table.insert(items, {
            text = row_text,
            callback = function()
                self_ref:showItemDetail(entry.item, entry.category_key,
                    entry.name, source, {
                        entries = conn_entries, index = captured_idx,
                        source = source,
                    })
            end,
            -- Some relationships run to several hundred characters — past what
            -- three wrapped lines hold. Hold shows the whole thing.
            hold_callback = function()
                UIManager:show(TextViewer:new{
                    title = entry.button_text,
                    text = row_text,
                    width = Screen:getWidth() * 0.9,
                    height = Screen:getHeight() * 0.6,
                })
            end,
        })
    end
    self:navigateForward(T(_("%1 — connections (%2)"), owner_title or _("Details"),
        #conn_entries), items, nil, {
        single_line = false,
        multilines_forced = true,
        items_max_lines = 3,
    })
end

--- Show detail view for a single item (overlays as TextViewer)
--- @param item table The item data
--- @param category_key string The category key
--- @param title string Display title
--- @param source table|nil Back-navigation chain (from connection links)
--- @param nav_context table|nil Category navigation {items, index, category_key, category_label}
--- Close the entity-detail overlay from an INTERNAL flow (back, arrows,
--- connections, group jump, manage ops, wiki, distribution) — never the
--- reader's own exit. Q6: showItemDetail's close_callback treats any onClose
--- OUTSIDE this wrapper as the reader closing the page, which on a direct
--- entry also closes the whole browser. onClose runs synchronously, so the
--- flag window is race-free.
function XrayBrowser:_dismissDetail(viewer)
    self._detail_nav_close = true
    if viewer then viewer:onClose() end
    self._detail_nav_close = nil
end

function XrayBrowser:showItemDetail(item, category_key, title, source, nav_context)
    require("koassistant_logger").dbg("KOAssistant XrayBrowser: entity",
        (item and item.name) or "?", "in", tostring(category_key),
        "source=", tostring(source or "browse"))
    -- Location for the group jump (round 25): the entity's own identity
    -- handles travel, so the next book resolves it even under another name.
    -- Round 26: the detail view is an OVERLAY, not a nav_stack level, so
    -- nothing pops this back when it closes — without the close_callback
    -- below, backing out to the category list left the location naming a
    -- character, and the next group jump opened that character in the other
    -- book ("strange behavior with character windows popping up").
    local restore_location = self.location
    local owner_file = self.metadata and self.metadata.book_file
    self.location = {
        category_key = category_key,
        category_label = nav_context and nav_context.category_label,
        item_name = XrayParser.getItemName(item, category_key),
        item_aliases = item.aliases,
    }
    -- Two texts. The page shows a trimmed one (connections are buttons plus a
    -- list, highlights are a button); "Chat about this" sends the FULL one —
    -- dropping connections from the display must not quietly shrink what the
    -- model is told about the entity.
    local chat_text = XrayParser.formatItemDetail(item, category_key)
    local detail_text = XrayParser.formatItemDetail(item, category_key,
        { omit_connections = true })

    -- For current state/position: prepend reading progress for clarity
    if (category_key == "current_state" or category_key == "current_position") and self.metadata.progress then
        detail_text = _("As of") .. " " .. self.metadata.progress .. "\n\n" .. detail_text
        chat_text = _("As of") .. " " .. self.metadata.progress .. "\n\n" .. chat_text
    end
    local item_highlights = {}
    -- Populated by the connections block below; the More… popup is built
    -- BEFORE it, and its callbacks run after, so the closure sees the filled list
    local conn_entries = {}

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
        -- Per-book privacy override (Book Settings ▸ Privacy): the highlights come
        -- from the OPEN book's live annotations, and this detail text is sent to
        -- the provider by "Chat about this" — deny beats trusted.
        if self.ui.doc_settings then
            local ov = require("koassistant_book_settings")
                .effectivePrivacyOverrides(self.ui.doc_settings).highlights
            if ov ~= nil then highlights_allowed = ov end
        end
        item_highlights = highlights_allowed and findItemHighlights(item, self.ui) or {}
        if #item_highlights > 0 then
            -- The chat context keeps them inline (that is the whole point of
            -- gating them on the sharing settings); the PAGE moves them behind
            -- a button. A well-highlighted character buried its own X-Ray
            -- description under a wall of quotes (device 2026-08-18).
            chat_text = chat_text .. "\n\n" .. _("Your highlights:") .. "\n"
            for _idx, hl in ipairs(item_highlights) do
                local display_hl = hl
                if #display_hl > 200 then
                    display_hl = display_hl:sub(1, 200) .. "..."
                end
                chat_text = chat_text .. "\n> " .. display_hl
            end
        end
    end

    local captured_ui = self.ui
    local self_ref = self

    -- Build navigation row: ← + nav buttons + [Chat about this]
    -- With category nav: ← ◀ ▶ [Chat]  (prev/next replace scroll buttons)
    -- Without nav:       ← ⇱ ⇲ [Chat]  (scroll top/bottom for long content)
    local row = {}
    local viewer  -- forward declaration for button callbacks
    local has_nav = nav_context and (
        (nav_context.items and #nav_context.items > 1) or
        (nav_context.entries and #nav_context.entries > 1))

    -- Back button: show source name when navigating from connections
    local back_text = "←"
    if source then
        local back_name = source.breadcrumb or source.title or ""
        if back_name ~= "" then
            if #back_name > 12 then
                back_name = back_name:sub(1, 10) .. "…"
            end
            back_text = "← " .. back_name
        end
    end
    table.insert(row, {
        text = back_text,
        callback = function()
            self_ref:_dismissDetail(viewer)
            if source then
                self_ref:showItemDetail(source.item, source.category_key,
                    source.title, source.source, source.nav_context)
            else
                -- Q6: ← with no source reveals the category list — on a
                -- direct entry that is the reader CHOOSING to browse, so the
                -- one-X exit stands down for this session
                self_ref._direct_entry_exit = nil
            end
        end,
    })

    -- Navigation closures for prev/next (used by buttons and page-turn keys)
    local navigatePrev, navigateNext
    if has_nav then
        local is_mixed = nav_context.entries ~= nil
        local nav_list = is_mixed and nav_context.entries or nav_context.items
        local nav_idx = nav_context.index
        local total = #nav_list
        local prev_idx = nav_idx > 1 and nav_idx - 1 or total
        local next_idx = nav_idx < total and nav_idx + 1 or 1

        navigatePrev = function()
            self_ref:_dismissDetail(viewer)
            if is_mixed then
                local entry = nav_list[prev_idx]
                self_ref:showItemDetail(entry.item, entry.category_key, entry.name, nav_context.source, {
                    entries = nav_list, index = prev_idx,
                    source = nav_context.source,
                })
            else
                local prev_item = nav_list[prev_idx]
                local prev_name = XrayParser.getItemName(prev_item, nav_context.category_key)
                self_ref:showItemDetail(prev_item, nav_context.category_key, prev_name, nil, {
                    items = nav_list, index = prev_idx,
                    category_key = nav_context.category_key, category_label = nav_context.category_label,
                })
            end
        end
        navigateNext = function()
            self_ref:_dismissDetail(viewer)
            if is_mixed then
                local entry = nav_list[next_idx]
                self_ref:showItemDetail(entry.item, entry.category_key, entry.name, nav_context.source, {
                    entries = nav_list, index = next_idx,
                    source = nav_context.source,
                })
            else
                local next_item = nav_list[next_idx]
                local next_name = XrayParser.getItemName(next_item, nav_context.category_key)
                self_ref:showItemDetail(next_item, nav_context.category_key, next_name, nil, {
                    items = nav_list, index = next_idx,
                    category_key = nav_context.category_key, category_label = nav_context.category_label,
                })
            end
        end

        table.insert(row, { text = "◀", callback = navigatePrev })
        table.insert(row, { text = "▶", callback = navigateNext })
    else
        table.insert(row, {
            text = "⇱",
            id = "top",
            callback = function()
                local sw = viewer and (viewer.scroll_widget or viewer.scroll_text_w)
                if sw then sw:scrollToTop() end
            end,
        })
        table.insert(row, {
            text = "⇲",
            id = "bottom",
            callback = function()
                local sw = viewer and (viewer.scroll_widget or viewer.scroll_text_w)
                if sw then sw:scrollToBottom() end
            end,
        })
    end

    if self.metadata.plugin and self.metadata.configuration then
        table.insert(row, {
            text = _("Chat about this"),
            callback = function()
                self_ref:chatAboutItem(chat_text, {
                    name = XrayParser.getItemName(item, category_key),
                    category = (nav_context and nav_context.category_label) or category_key,
                })
            end,
        })
    end

    local buttons_rows = {}

    -- "→ Group" (round 26 device report): the row that carries this jump lives
    -- on the category Menu's hamburger, which this full-screen detail covers —
    -- and an entity page is exactly where "show me this character in the other
    -- volume" is worth having. Round 27 placement (maintainer: "maybe
    -- additional slot far right top row?"): it JOINS the top row rather than
    -- taking a line of its own between the top row and the connections.
    local group_button
    if not self.scope and not self.metadata.checkpoint
        and self.metadata.plugin and self.metadata.book_file
        and self.metadata.plugin._inBookGroup
        and self.metadata.plugin:_inBookGroup(self.metadata.book_file) then
        local plugin_ref = self.metadata.plugin
        local group_file = self.metadata.book_file
        group_button = {
            text = "→ " .. _("Group"),
            callback = function()
                local jump_location = self_ref.location
                plugin_ref:_showGroupMembersPopup(group_file, "xray", {
                    location = jump_location,
                    before_open = function()
                        self_ref:_dismissDetail(viewer)
                        if self_ref.menu then UIManager:close(self_ref.menu) end
                    end,
                })
            end,
        }
    end

    -- "Chapter Appearances" + "Add Search Term" row (searchable categories)
    if not DISTRIBUTION_EXCLUDED[category_key] then
        local search_row = {}
        local dist_item_name = XrayParser.getItemName(item, category_key)
        table.insert(search_row, {
            text = _("Chapter Appearances"),
            callback = function()
                if self_ref.ui and self_ref.ui.document then
                    -- Don't close viewer here; it stays visible as a loading screen
                    -- while distribution computes, then closes in _buildDistributionView
                    self_ref:showItemDistribution(item, category_key, dist_item_name, {
                        source = source,
                        nav_context = nav_context,
                        dismiss_viewer = viewer,
                    })
                else
                    self_ref:_showReaderRequired({
                        category_key = category_key,
                        item_name = dist_item_name,
                    })
                end
            end,
        })
        -- AI Wiki button (generates/views per-item encyclopedia entry)
        if self.metadata.plugin and self.metadata.configuration and self.metadata.book_file then
            local ActionCache = require("koassistant_action_cache")
            local item_name = item.name or item.term or ""
            local wiki_cached = ActionCache.getWikiEntry(self.metadata.book_file, category_key, item_name)
            table.insert(search_row, {
                text = wiki_cached and _("View AI Wiki") or _("AI Wiki"),
                callback = function()
                    if wiki_cached then
                        self_ref:showWikiViewer(item, category_key, wiki_cached, title, source, nav_context)
                    else
                        self_ref:runWikiForItem(item, category_key, title, source, nav_context)
                    end
                end,
            })
        end
        if self.metadata.book_file then
            -- "Edit…" (2026-08-09 maintainer): ONE entry-management popup
            -- instead of per-op buttons — search terms + "move back to carried"
            -- now; rename and manual merge are queued to join it (unified
            -- entry-management direction)
            table.insert(search_row, {
                text = _("More…"),
                callback = function()
                    self_ref:_showEntityManagePopup(item, category_key, title,
                        source, nav_context, viewer, true,
                        { connections = conn_entries, highlights = item_highlights })
                end,
            })
        end
        if group_button then
            table.insert(search_row, group_button)
            group_button = nil
        end
        if #search_row > 0 then
            table.insert(buttons_rows, search_row)
        end
    end
    -- Categories with no top row (distribution-excluded): management keeps a
    -- fallback row rather than disappearing — Edit… appears here only when it
    -- has something to offer (the carried-list op; search terms belong to
    -- searchable categories). arguments/findings ARE carried cross-book
    -- (round 27 full inclusion), so the op must stay reachable on them.
    local fallback_row = {}
    if DISTRIBUTION_EXCLUDED[category_key] and self.metadata.book_file
        and not self.scope and not self.metadata.checkpoint
        and type(item) == "table" and type(item.background) == "table"
        and #item.background > 0 then
        table.insert(fallback_row, {
            text = _("More…"),
            callback = function()
                self_ref:_showEntityManagePopup(item, category_key, title,
                    source, nav_context, viewer, false,
                    { connections = conn_entries, highlights = item_highlights })
            end,
        })
    end
    if group_button then
        table.insert(fallback_row, group_button)
    end
    if #fallback_row > 0 then
        table.insert(buttons_rows, fallback_row)
    end

    -- Resolve references into tappable cross-category navigation buttons
    if self.xray_data then
        -- Characters/key_figures: resolve connections (other characters/items)
        -- Other categories: resolve references or characters field
        local names_list
        if category_key == "characters" or category_key == "key_figures" or category_key == "referenced_works" then
            names_list = item.connections
        else
            names_list = item.references or item.characters
        end
        if type(names_list) == "string" and names_list ~= "" then
            names_list = { names_list }
        end
        if type(names_list) == "table" and #names_list > 0 then
            -- breadcrumb: short name for trail display (from connection nav_context if available)
            local breadcrumb_name
            if nav_context and nav_context.entries and nav_context.entries[nav_context.index] then
                breadcrumb_name = nav_context.entries[nav_context.index].button_text
            end
            local current_source = {
                item = item,
                category_key = category_key,
                title = title,
                breadcrumb = breadcrumb_name,
                source = source,  -- Preserve chain for deep back-navigation
                nav_context = nav_context,  -- Preserve prev/next navigation for back-button
            }
            -- Resolve all connections first for nav_context
            -- Collapse by TARGET, not by string: a revision restates a
            -- relationship by extending its annotation, so several strings can
            -- name the same entity — and the button label is the bare name, so
            -- they rendered as identical repeated buttons and the ◀/▶ carousel
            -- walked the same entry several times with an inflated (i/N).
            local seen_target = {}
            for _idx, name_str in ipairs(names_list) do
                local resolved = XrayParser.resolveConnection(self.xray_data, name_str)
                if resolved and resolved.item ~= item          -- skip self-references
                    and not seen_target[resolved.item] then
                    seen_target[resolved.item] = true
                    table.insert(conn_entries, {
                        item = resolved.item,
                        category_key = resolved.category_key,
                        name = resolved.item.name or resolved.item.term
                            or resolved.item.event or _("Details"),
                        button_text = resolved.name_portion,
                        -- The annotation is what tells two connections apart;
                        -- the button drops it for width, the list shows it in full
                        relationship = resolved.relationship,
                        raw = name_str,
                    })
                end
            end
            -- Build connection buttons with nav_context for prev/next arrows.
            -- Only the first `cap` are DRAWN; the nav_context keeps every
            -- distinct connection, so the arrows still reach them all.
            local cap = tonumber(((self.metadata.configuration or {}).features or {})
                .xray_connection_buttons) or CONNECTION_BUTTONS_DEFAULT
            -- `cap` is the number of BOXES the row block may hold. Past it the
            -- last box becomes the overflow row, so a long list still costs
            -- exactly cap boxes; at or under it every connection is drawn and
            -- no extra button appears (the list lives in More… instead).
            local overflowing = #conn_entries > cap
            local drawn = overflowing and math.max(cap - 1, 0) or #conn_entries
            local conn_row = {}
            for conn_idx = 1, drawn do
                local entry = conn_entries[conn_idx]
                local captured_idx = conn_idx
                table.insert(conn_row, {
                    text = entry.button_text,
                    callback = function()
                        self_ref:_dismissDetail(viewer)
                        self_ref:showItemDetail(entry.item,
                            entry.category_key,
                            entry.name, current_source, {
                            entries = conn_entries, index = captured_idx,
                            source = current_source,
                        })
                    end,
                })
                -- Start a new row every 3 buttons
                if #conn_row == 3 then
                    table.insert(buttons_rows, conn_row)
                    conn_row = {}
                end
            end
            if overflowing then
                local list_button = {
                    text = T(_("All connections (%1)…"), #conn_entries),
                    callback = function()
                        self_ref:_dismissDetail(viewer)
                        self_ref:_showConnectionList(conn_entries, current_source, title)
                    end,
                }
                if #conn_row < 3 then
                    table.insert(conn_row, list_button)
                    table.insert(buttons_rows, conn_row)
                else
                    table.insert(buttons_rows, conn_row)
                    table.insert(buttons_rows, { list_button })
                end
            elseif #conn_row > 0 then
                table.insert(buttons_rows, conn_row)
            end
        end
    end

    -- Navigation bar (last row — arrows + chat)
    table.insert(buttons_rows, row)

    -- Title: prepend position indicator when navigating within a category/list
    local display_title = title or _("Details")
    if nav_context then
        local nav_list = nav_context.entries or nav_context.items
        if nav_list then
            display_title = T("(%1/%2) %3", nav_context.index, #nav_list, display_title)
        end
    end

    viewer = TextViewer:new{
        title = display_title,
        text = detail_text,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        buttons_table = buttons_rows,
        -- Newer KOReader (2026-06+): first-class boundary fall-through for
        -- page-turn keys; nil when no nav context (fields then unused)
        page_turn_callback_prev = navigatePrev,
        page_turn_callback_next = navigateNext,
        -- Pop the entity location when this overlay closes (round 26). The
        -- book guard keeps a late close from rewriting another book's
        -- location; the ◀/▶ and connection paths close THEN re-open, so the
        -- restore always lands before the next assignment.
        close_callback = function()
            if self_ref.metadata and self_ref.metadata.book_file == owner_file then
                self_ref.location = restore_location
            end
            -- Q6 (consolidation round, 2026-08-16): a DIRECTLY-entered entity
            -- page (mark tap, dict/highlight intercepts, lookup exact-match,
            -- card tap-through — the opener sets _direct_entry_exit) exits the
            -- WHOLE browser in one X: the reader came to read one entry, not
            -- to browse, and the category list underneath is chrome they
            -- never opened. Internal close-then-reopen flows (back, arrows,
            -- connections, group jump, manage ops, distribution) go through
            -- _dismissDetail, which suppresses this; browsing entries never
            -- set the flag, so their X keeps the parent-reveal.
            if self_ref._direct_entry_exit and not self_ref._detail_nav_close then
                self_ref._direct_entry_exit = nil
                if self_ref.menu then UIManager:close(self_ref.menu) end
            end
        end,
        text_selection_callback = function(text, hold_duration)
            handleTextSelection(text, hold_duration, {
                ui = captured_ui,
                plugin = self_ref.metadata.plugin,
                viewer = viewer,
                book_file = self_ref.metadata.book_file,
                book_title = self_ref.metadata.title,
            })
        end,
    }
    -- highlight_text_selection and HoldPanText gesture fix are handled globally
    -- by patchTextSelectionHandlers() in main.lua
    -- Hook page-turn keys for prev/next navigation when at scroll boundaries,
    -- for KOReader versions without page_turn_callback_* (pre 2026-06).
    -- ScrollTextWidget.onScrollUp/Down return nil at top/bottom boundaries,
    -- letting the event propagate. We catch it to navigate items.
    -- (scroll_widget = post-2026-07 field name, scroll_text_w = older)
    if navigatePrev and navigateNext and (viewer.scroll_widget or viewer.scroll_text_w) then
        local stw = viewer.scroll_widget or viewer.scroll_text_w
        local orig_onScrollUp = stw.onScrollUp
        stw.onScrollUp = function(self_w)
            local result = orig_onScrollUp(self_w)
            if result then return result end
            navigatePrev()
            return true
        end
        local orig_onScrollDown = stw.onScrollDown
        stw.onScrollDown = function(self_w)
            local result = orig_onScrollDown(self_w)
            if result then return result end
            navigateNext()
            return true
        end
    end
    -- Store reference so wiki generation can close and re-open with fresh button state
    self._detail_viewer = viewer
    UIManager:show(viewer)
end

--- Show dialog to add a custom search term for an item
--- Unified edit dialog for search terms: add, remove user terms, ignore/restore AI terms
--- @param item table The item data
--- @param category_key string The category key
--- @param item_title string Display title for refreshing detail view
--- @param source table|nil Navigation source for back-button chain
--- @param nav_context table|nil Category navigation context (preserved for detail view)
--- Entity history through the stored versions (maintainer request 2026-08-17):
--- a mechanical, no-AI walk of ONE entity across every version on disk —
--- ladder rungs + archived ring versions + the installed artifact (a
--- promotion COPY, folded onto its source rung) — rendered oldest to newest
--- with unchanged spans collapsed. Under spoiler protection, versions past
--- max(position, installed coverage) stay concealed behind the standard
--- reveal confirm; a complete INSTALL stands the gate down (round-7 ruling).
--- @param item table The entity (from the hosting view)
--- @param category_key string Its category
--- @param reveal boolean|nil true = concealed versions shown (post-confirm)
function XrayBrowser:showEntityHistory(item, category_key, reveal)
    local ActionCache = require("koassistant_action_cache")
    local file = self.metadata and self.metadata.book_file
    if not file then return end
    local entry_name = XrayParser.getItemName(item, category_key)
    -- Identity handles: name + aliases, so a renamed/bridged entity resolves
    -- in versions that knew it under another handle
    local names = { entry_name }
    if type(item.aliases) == "table" then
        for _idx, a in ipairs(item.aliases) do
            if type(a) == "string" and a ~= "" then names[#names + 1] = a end
        end
    elseif type(item.aliases) == "string" and item.aliases ~= "" then
        names[#names + 1] = item.aliases
    end

    -- Current lineage only: ladder rungs + the installed artifact. Ring
    -- archives are superseded lineages / pre-op snapshots (device round
    -- 2026-08-17: an old archived COMPLETE build sorted past the reader's
    -- gate and the footer advertised it as a "later version") — they stay
    -- reachable via All versions, never in this walk.
    local versions = {}
    for _idx, rung in ipairs(ActionCache.getXrayLadder(file)) do
        versions[#versions + 1] = { src = rung, kind = "checkpoint" }
    end
    local live = ActionCache.getXrayCache(file)
    if live and live.result then
        versions[#versions + 1] = { src = live, kind = "installed" }
    end

    local rows = {}
    for _idx, v in ipairs(versions) do
        local src = v.src
        if type(src.result) == "string" then
            local data = XrayParser.parse(src.result)
            local found = data and XrayParser.findByIdentity(data, names, category_key)
            if found then
                local cov = tonumber(src.progress_decimal) or 0
                if src.full_document then cov = 1 end
                local aliases = {}
                if type(found.aliases) == "table" then
                    for _i, a in ipairs(found.aliases) do
                        if type(a) == "string" then aliases[#aliases + 1] = a end
                    end
                elseif type(found.aliases) == "string" then
                    aliases[1] = found.aliases
                end
                rows[#rows + 1] = {
                    cov = cov,
                    ts = tonumber(src.timestamp) or 0,
                    kind = v.kind,
                    complete = (src.full_document or cov >= 0.995) and true or nil,
                    description = tostring(found.description or ""),
                    aliases = table.concat(aliases, ", "),
                }
            end
        end
    end
    if #rows == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No stored versions carry this entry."),
        })
        return
    end
    table.sort(rows, function(a, b)
        if a.cov ~= b.cov then return a.cov < b.cov end
        return a.ts < b.ts
    end)
    -- Fold the installed copy onto its source rung (identical coverage+text
    -- in either adjacency order); a diverged install keeps its own row
    local folded = {}
    for _idx, r in ipairs(rows) do
        local prev = folded[#folded]
        if prev and prev.cov == r.cov and prev.description == r.description
            and (r.kind == "installed" or prev.kind == "installed") then
            prev.installed = true
            if prev.kind == "installed" then prev.kind = r.kind end
        else
            r.installed = r.kind == "installed" or nil
            folded[#folded + 1] = r
        end
    end
    rows = folded

    -- Spoiler gate at version granularity (mirrors _spoilerGate's resolution)
    local gate
    do
        local BookSettings = require("koassistant_book_settings")
        local SafeDocSettings = require("koassistant_doc_settings")
        local ds = SafeDocSettings.resolve(file, self.ui)
        local features = self.metadata and self.metadata.configuration
            and self.metadata.configuration.features
        if BookSettings.resolveSpoilerFree(ds, features) then
            local g = 0
            if live then
                if live.full_document then g = 1 end
                g = math.max(g, tonumber(live.progress_decimal) or 0)
            end
            local ui = self.ui
            if ui and ui.document and ui.document.info
                and (ui.document.info.number_of_pages or 0) > 0 then
                g = math.max(g, (getCurrentPage(ui) or 0) / ui.document.info.number_of_pages)
            elseif ds and ds.readSetting then
                local pf = tonumber(ds:readSetting("percent_finished"))
                if pf then g = math.max(g, pf) end
            end
            if g < 0.995 then gate = g end
        end
    end
    local concealed = 0
    if gate and not reveal then
        local visible = {}
        for _idx, r in ipairs(rows) do
            if r.cov <= gate + 0.001 then
                visible[#visible + 1] = r
            else
                concealed = concealed + 1
            end
        end
        rows = visible
    end

    -- Collapse unchanged spans (description + aliases + kind identical)
    local blocks = {}
    for _idx, r in ipairs(rows) do
        local prev = blocks[#blocks]
        if prev and prev.description == r.description and prev.aliases == r.aliases
            and prev.kind == r.kind then
            prev.to_cov = r.cov
            prev.installed = prev.installed or r.installed
        else
            blocks[#blocks + 1] = {
                from_cov = r.cov, to_cov = r.cov, ts = r.ts, kind = r.kind,
                complete = r.complete, installed = r.installed,
                description = r.description, aliases = r.aliases,
            }
        end
    end

    local function pct(c) return string.format("%d%%", math.floor(c * 100 + 0.5)) end
    local parts = {}
    for _idx, b in ipairs(blocks) do
        local head
        if b.complete then
            head = _("Complete")
        elseif b.to_cov > b.from_cov then
            head = T(_("To %1, unchanged through %2"), pct(b.from_cov), pct(b.to_cov))
        else
            head = T(_("To %1"), pct(b.from_cov))
        end
        if b.ts and b.ts > 0 then
            head = head .. " · " .. os.date("%Y-%m-%d", b.ts)
        end
        if b.installed then
            head = head .. " · " .. _("installed")
        end
        parts[#parts + 1] = "[" .. head .. "]"
        if b.aliases ~= "" then
            parts[#parts + 1] = T(_("Aliases: %1"), b.aliases)
        end
        parts[#parts + 1] = b.description
        parts[#parts + 1] = ""
    end
    if #blocks == 0 and concealed > 0 then
        parts[#parts + 1] = _("Every version carrying this entry is beyond your reading position.")
        parts[#parts + 1] = ""
    end
    if concealed > 0 then
        parts[#parts + 1] = T(_("%1 later version(s) concealed (spoiler protection)."), concealed)
    end

    local self_ref = self
    local viewer
    local button_row = {}
    if concealed > 0 then
        table.insert(button_row, {
            text = _("Show later versions"),
            callback = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("The later versions are beyond your reading position and may contain spoilers.\n\nShow them?"),
                    ok_text = _("Show them"),
                    ok_callback = function()
                        UIManager:close(viewer)
                        self_ref:showEntityHistory(item, category_key, true)
                    end,
                })
            end,
        })
    end
    table.insert(button_row, {
        text = _("Close"),
        callback = function() UIManager:close(viewer) end,
    })
    viewer = TextViewer:new{
        title = T(_("History: %1"), tostring(entry_name)),
        text = table.concat(parts, "\n"),
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        buttons_table = { button_row },
    }
    UIManager:show(viewer)
end

--- One popup for per-entry management (2026-08-09 unified entry-management
--- direction, "Manage…"): search terms + rename + move-back-to-carried;
--- merge-with-another-entry is the queued addition (needs an entity picker —
--- the dedup scan covers duplicate merges today). Replaces the per-op
--- detail-page buttons.
--- @param can_edit_terms boolean Search-terms row (searchable categories only)
--- @param view_payload table|nil { connections = resolved+deduped entries,
---   highlights = the reader's matching annotations } — the READ rows. The
---   popup is built before the connection block fills its list, so these are
---   closures over locals that are populated by the time a callback runs.
function XrayBrowser:_showEntityManagePopup(item, category_key, title, source, nav_context, viewer, can_edit_terms, view_payload)
    local ButtonDialog = require("ui/widget/buttondialog")
    local self_ref = self
    local dialog
    local buttons = {}
    -- Shared gates (hoisted 2026-08-17 for the History row): live main views
    -- only for WRITE ops; History is a read view, offered from checkpoint
    -- views too (same walk), sections excluded (main-lineage versions would
    -- mislead about a section entity)
    local live_main = not self.scope and not self.metadata.checkpoint
        and self.metadata.book_file
    local entry_name = XrayParser.getItemName(item, category_key)
    local named = type(entry_name) == "string" and entry_name ~= ""
    -- History through checkpoints (maintainer request 2026-08-17): mechanical
    -- per-entity walk across the current lineage (ladder rungs + installed);
    -- only offered when rungs exist (O(1) header count) — ring archives are
    -- out of the walk, so a ring-only book has no history to show
    if not self.scope and named and self.metadata.book_file then
        local ActionCache = require("koassistant_action_cache")
        local vcount = ActionCache.getXrayLadderCount(self.metadata.book_file) or 0
        if vcount > 0 then
            table.insert(buttons, {{
                text = _("History through checkpoints…"),
                callback = function()
                    UIManager:close(dialog)
                    self_ref:showEntityHistory(item, category_key)
                end,
            }})
        end
    end
    -- Reading rows. The entity page draws up to CONNECTION_BUTTONS_DEFAULT
    -- connection buttons and only grows an "All connections" box once it
    -- overflows, so at or under the cap this is where the full list (with the
    -- relationship text) lives. Highlights are here for the same reason: they
    -- are worth reading, not worth spending the page on.
    local payload = view_payload or {}
    if type(payload.connections) == "table" and #payload.connections > 0 then
        table.insert(buttons, {{
            text = T(_("List connections (%1)…"), #payload.connections),
            callback = function()
                UIManager:close(dialog)
                self_ref:_dismissDetail(viewer)
                self_ref:_showConnectionList(payload.connections, source, title)
            end,
        }})
    end
    if type(payload.highlights) == "table" and #payload.highlights > 0 then
        table.insert(buttons, {{
            text = T(_("Your highlights (%1)…"), #payload.highlights),
            callback = function()
                UIManager:close(dialog)
                local body = {}
                for _idx, hl in ipairs(payload.highlights) do
                    body[#body + 1] = "> " .. hl
                end
                UIManager:show(TextViewer:new{
                    title = title or _("Your highlights"),
                    text = table.concat(body, "\n\n"),
                    width = Screen:getWidth() * 0.9,
                    height = Screen:getHeight() * 0.8,
                })
            end,
        }})
    end
    -- Split the reading rows above from the ops below (maintainer 2026-08-18).
    -- ButtonTable already rules between every row, so a disabled row reads as
    -- the double line asked for, and labelling it says WHY the split is there.
    local ops_start = #buttons
    if can_edit_terms then
        table.insert(buttons, {{
            text = _("Edit search terms"),
            callback = function()
                UIManager:close(dialog)
                self_ref:editSearchTerms(item, category_key, title, source, nav_context)
            end,
        }})
    end
    -- Rename (2026-08-09): live main views only — the commit path writes the
    -- MAIN artifact, so a section/checkpoint view must not offer it
    if live_main and named then
        table.insert(buttons, {{
            text = _("Rename…"),
            callback = function()
                UIManager:close(dialog)
                self_ref:_renameEntity(item, category_key, viewer)
            end,
        }})
    end
    -- Merge with another entry (2026-08-09 round): the dedup flow's manual
    -- picker, seeded with THIS entry — same keep/AI-merge options and the
    -- same commit (+ ring archive). The browser unwinds to a fresh root
    -- instead of closing (a merge rewrites the data the stacked pages hold);
    -- the commit's reloadLiveMain then keeps that root honest.
    if live_main and named and self.metadata.plugin then
        table.insert(buttons, {{
            text = _("Merge with another entry…"),
            callback = function()
                UIManager:close(dialog)
                self_ref:_dismissDetail(viewer)
                self_ref:_unwindToRoot()
                require("koassistant_xray_dedup").startFlow({
                    file = self_ref.metadata.book_file,
                    ui = self_ref.ui,
                    plugin = self_ref.metadata.plugin,
                    configuration = self_ref.metadata.configuration,
                    title = self_ref.metadata.title,
                    author = self_ref.metadata.book_author,
                    manual_seed = { cat_key = category_key, name = entry_name },
                    close_browser = function() end, -- root stays; reloadLiveMain refreshes it
                })
            end,
        }})
    end
    -- Link with a group member's entry (2026-08-09 round, cross-book
    -- identity): each side gains the other's names as aliases, so group
    -- navigation, carry/wake matching and future folds treat them as one
    -- entity. Aliases only — no content copied, no request made.
    if live_main and named and self.metadata.plugin
        and self.metadata.plugin._inBookGroup
        and self.metadata.plugin:_inBookGroup(self.metadata.book_file) then
        table.insert(buttons, {{
            text = _("Link with a group member's entry…"),
            callback = function()
                UIManager:close(dialog)
                self_ref:_linkEntityFlow(item, category_key, entry_name, viewer)
            end,
        }})
    end
    -- "Move back to carried list" — the way back out of "Add as its own entry"
    -- (round 27 maintainer: "it could easily be done by accident and there is
    -- no way back"). Offered only for entries that carry cross-book background:
    -- those belong to an earlier book, so the carried list is an honest home.
    -- A native entry of THIS book would be mislabeled there — removing one of
    -- those is the separate "edit/delete X-Ray entries" question. Undo is
    -- LOCAL: a fold that already copied this forward is not rewritten, exactly
    -- like any other later edit.
    if not self.scope and not self.metadata.checkpoint and self.metadata.book_file
        and type(item) == "table" and type(item.background) == "table"
        and #item.background > 0 then
        local demote_name = XrayParser.getItemName(item, category_key)
        if type(demote_name) == "string" and demote_name ~= "" then
            table.insert(buttons, {{
                text = _("Move back to carried list"),
                callback = function()
                    UIManager:close(dialog)
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Move \"%1\" out of this book's X-Ray and back to the carried list?\nIts history from earlier books is kept, and its entry page can add it back."), demote_name),
                        ok_text = _("Move"),
                        ok_callback = function()
                            self_ref:_dismissDetail(viewer)
                            if self_ref:_commitDormantOp(
                                function(data)
                                    return XrayParser.demoteToStub(data, category_key, demote_name)
                                end,
                                T(_("\"%1\" moved back to the carried list."), demote_name)) then
                                -- Back to root: the entry this page rendered no
                                -- longer exists, and the pages under it hold
                                -- item tables that still list it
                                while #self_ref.nav_stack > 0 do self_ref:navigateBack() end
                            end
                        end,
                    })
                end,
            }})
        end
    end
    if ops_start > 0 and #buttons > ops_start then
        table.insert(buttons, ops_start + 1,
            {{ text = _("— Edit this entry —"), enabled = false }})
    end
    table.insert(buttons, {{
        text = _("Cancel"),
        callback = function() UIManager:close(dialog) end,
    }})
    dialog = ButtonDialog:new{
        title = XrayParser.getItemName(item, category_key) or title,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Manage ▸ Link, step 1: pick a group member (X-Ray'd members enabled).
--- The flow: member → their entry (same category family) → confirm → alias
--- bridge written BOTH ways, remote book first.
function XrayBrowser:_linkEntityFlow(item, category_key, link_name, viewer)
    local BookGroups = require("koassistant_book_groups")
    local ActionCache = require("koassistant_action_cache")
    local ButtonDialog = require("ui/widget/buttondialog")
    local book_file = self.metadata.book_file
    local self_ref = self
    -- This entry's identity handles (name + aliases) — what the member gains
    local our_names = { link_name }
    for _idx, a in ipairs(type(item.aliases) == "table" and item.aliases or {}) do
        if type(a) == "string" and a ~= "" then our_names[#our_names + 1] = a end
    end
    local seen_paths, mates = { [book_file] = true }, {}
    for _g, group in ipairs(BookGroups.groupsFor(book_file)) do
        for _i, path in ipairs(group.books) do
            if not seen_paths[path] then
                seen_paths[path] = true
                mates[#mates + 1] = path
            end
        end
    end
    if #mates == 0 then return end
    local family = XrayParser.CATEGORY_FAMILY[category_key] or category_key
    local mate_dialog
    local rows = {}
    for _idx, path in ipairs(mates) do
        local captured = path
        local mate_title = BookGroups.displayTitle(captured, self.ui)
        local ok, entry = pcall(ActionCache.getXrayCache, captured)
        if ok and entry and entry.result then
            rows[#rows + 1] = {{ text = mate_title, align = "left",
                callback = function()
                    UIManager:close(mate_dialog)
                    self_ref:_linkPickRemote(captured, mate_title, entry, family,
                        category_key, link_name, our_names, viewer)
                end }}
        else
            rows[#rows + 1] = {{ text = mate_title .. " " .. _("(no X-Ray)"),
                align = "left", enabled = false }}
        end
    end
    rows[#rows + 1] = {{ text = _("Cancel"),
        callback = function() UIManager:close(mate_dialog) end }}
    mate_dialog = ButtonDialog:new{
        title = T(_("Link \"%1\" with an entry in…"), link_name),
        buttons = rows,
    }
    UIManager:show(mate_dialog)
end

--- Manage ▸ Link, step 2: pick the member's entry — same category FAMILY
--- (people never link to glossary terms, the wake-pass scoping), the entry
--- already matching our identity marked "(already linked)".
function XrayBrowser:_linkPickRemote(member_file, member_title, entry, family,
        category_key, link_name, our_names, viewer)
    local ButtonDialog = require("ui/widget/buttondialog")
    local parsed = XrayParser.parse(entry.result)
    if not parsed or parsed.error then
        UIManager:show(InfoMessage:new{
            text = _("That book's X-Ray could not be parsed."), timeout = 3 })
        return
    end
    local self_ref = self
    local existing = XrayParser.findByIdentity(parsed, our_names, category_key)
    local dialog
    local rows = {}
    for _idx, cat in ipairs(XrayParser.getCategories(parsed)) do
        if (XrayParser.CATEGORY_FAMILY[cat.key] or cat.key) == family
            and type(cat.items) == "table" then
            for _i, it in ipairs(cat.items) do
                local nm = XrayParser.getItemName(it, cat.key)
                if type(nm) == "string" and nm ~= "" then
                    if existing and it == existing then
                        rows[#rows + 1] = {{ text = nm .. " " .. _("(already linked)"),
                            align = "left", enabled = false }}
                    else
                        local c_it, c_key, c_nm = it, cat.key, nm
                        rows[#rows + 1] = {{ text = nm, align = "left",
                            callback = function()
                                UIManager:close(dialog)
                                self_ref:_confirmLink(member_file, member_title,
                                    entry, parsed, c_it, c_key, c_nm,
                                    category_key, link_name, our_names, viewer)
                            end }}
                    end
                end
            end
        end
    end
    if #rows == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("\"%1\" has no named entries in this category family."), member_title),
            timeout = 3 })
        return
    end
    rows[#rows + 1] = {{ text = _("Cancel"),
        callback = function() UIManager:close(dialog) end }}
    dialog = ButtonDialog:new{
        title = T(_("Link \"%1\" with which entry of \"%2\"?"), link_name, member_title),
        buttons = rows,
    }
    UIManager:show(dialog)
end

--- Manage ▸ Link, step 3: confirm, then commit — REMOTE side first (its
--- failure leaves this book untouched), then the local side via the
--- dormant-op commit. Both sides ring-archive their pre-link version.
function XrayBrowser:_confirmLink(member_file, member_title, entry, parsed,
        r_item, r_cat, r_name, category_key, link_name, our_names, viewer)
    local ConfirmBox = require("ui/widget/confirmbox")
    local self_ref = self
    UIManager:show(ConfirmBox:new{
        text = T(_("Link \"%1\" (this book) with \"%2\" (%3)?\nEach book's entry gains the other's names as aliases, so group navigation and future folds treat them as the same. No content is copied."),
            link_name, r_name, member_title),
        ok_text = _("Link"),
        ok_callback = function()
            self_ref:_commitLink(member_file, member_title, entry, parsed,
                r_item, r_cat, r_name, category_key, link_name, our_names, viewer)
        end,
    })
end

function XrayBrowser:_commitLink(member_file, member_title, entry, parsed,
        r_item, r_cat, r_name, category_key, link_name, our_names, viewer)
    local WriteBack = require("koassistant_artifact_writeback")
    local json = require("json")
    local their_names = { r_name }
    for _idx, a in ipairs(type(r_item.aliases) == "table" and r_item.aliases or {}) do
        if type(a) == "string" and a ~= "" then their_names[#their_names + 1] = a end
    end
    if not XrayParser.addItemAliases(parsed, r_cat, r_name, our_names) then
        UIManager:show(InfoMessage:new{
            text = _("That entry changed on disk — reopen and retry."), timeout = 3 })
        return
    end
    local okj, member_json = pcall(json.encode, parsed, { pretty = true, indent = true })
    if not okj or type(member_json) ~= "string" then
        UIManager:show(InfoMessage:new{
            text = _("Failed to serialize the member's X-Ray."), timeout = 3 })
        return
    end
    -- Continuity meta, the dedup commit's convention: the fresh timestamp
    -- marks the modification, everything else rides through
    local meta = {}
    for k, v in pairs(entry) do meta[k] = v end
    meta.result, meta.timestamp, meta.progress_decimal = nil, nil, nil
    local ok_remote = WriteBack.commitXray(member_file, member_json,
        entry.progress_decimal or 0, meta, {
            prev = entry,
            features = (self.metadata.configuration and self.metadata.configuration.features) or {},
            refresh_fn = function()
                -- No-op unless that book's browser is somehow live
                require("koassistant_xray_browser"):reloadLiveMain(member_file)
            end,
        })
    if not ok_remote then
        UIManager:show(InfoMessage:new{
            text = _("Could not write the member book's X-Ray — nothing was linked."),
            timeout = 4 })
        return
    end
    self:_dismissDetail(viewer)
    if self:_commitDormantOp(
        function(data)
            return XrayParser.addItemAliases(data, category_key, link_name, their_names)
        end,
        T(_("Linked \"%1\" with \"%2\" (%3)."), link_name, r_name, member_title)) then
        self:_rebuildToDetail(category_key, link_name)
    else
        -- The remote write landed; only this book's side is missing
        UIManager:show(InfoMessage:new{
            text = _("The member book was linked, but this book's write failed — run the link again to finish this side."),
            timeout = 5 })
    end
end

--- Reset navigation to a freshly built root in ONE switchItemTable — after a
--- commit rewrote the data, every stacked page holds stale item tables.
function XrayBrowser:_unwindToRoot()
    if not self.menu then return end
    self.nav_stack = {}
    self.location = nil
    local base_paths = self._level_up and 1 or 0
    while #self.menu.paths > base_paths do table.remove(self.menu.paths) end
    self.menu:switchItemTable(self:buildMainTitle(), self:buildCategoryItems(), -1)
end

--- Rebuild root → category → detail for a named entry synchronously — the
--- switchItemTable calls batch into one repaint (the search-return pattern).
--- Shared by rename and link, which change an entry and stay on it.
function XrayBrowser:_rebuildToDetail(category_key, name)
    if not self.menu then return end
    self:_unwindToRoot()
    for _idx, cat in ipairs(XrayParser.getCategories(self.xray_data) or {}) do
        if cat.key == category_key then
            self:showCategoryItems(cat)
            break
        end
    end
    for _idx, it in ipairs((self.xray_data and self.xray_data[category_key]) or {}) do
        if XrayParser.getItemName(it, category_key) == name then
            self:showItemDetail(it, category_key, name)
            break
        end
    end
end

--- Rename input (Manage ▸ Rename…): pre-filled with the current name.
function XrayBrowser:_renameEntity(item, category_key, viewer)
    local old_name = XrayParser.getItemName(item, category_key)
    if type(old_name) ~= "string" or old_name == "" then return end
    local self_ref = self
    local input
    input = InputDialog:new{
        title = T(_("Rename \"%1\""), old_name),
        input = old_name,
        description = _("The old name is kept as an alias, so the AI still knows who this is in updates and merges."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(input)
            end },
            { text = _("Rename"), is_enter_default = true, callback = function()
                local new_name = input:getInputText()
                new_name = new_name and new_name:match("^%s*(.-)%s*$") or ""
                UIManager:close(input)
                if new_name == "" or new_name == old_name then return end
                self_ref:_commitRename(category_key, old_name, new_name, viewer)
            end },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

--- Commit a rename: artifact via the dedup commit pattern (ring-archive =
--- built-in undo), then re-key the name-keyed side stores (wiki, search
--- terms, never-merge), then the matching follow-up — the old name stays
--- model-visible as an alias either way; whether it keeps matching THE TEXT
--- is the reader's call (the "Andy" case: a nickname that would match
--- strangers in the running text).
function XrayBrowser:_commitRename(category_key, old_name, new_name, viewer)
    local book_file = self.metadata.book_file
    if not self:_commitDormantOp(
        function(data)
            return XrayParser.renameItem(data, category_key, old_name, new_name)
        end,
        T(_("\"%1\" renamed to \"%2\"."), old_name, new_name)) then
        return
    end
    local ActionCache = require("koassistant_action_cache")
    ActionCache.renameEntityKeys(book_file, category_key, old_name, new_name)
    -- STAY IN PLACE (maintainer 2026-08-09, replacing the unwind-to-root):
    -- rebuild the path to the renamed detail synchronously, so no page in the
    -- fresh stack holds pre-rename item tables
    self:_dismissDetail(viewer)
    self:_rebuildToDetail(category_key, new_name)
    local ConfirmBox = require("ui/widget/confirmbox")
    local self_ref = self
    UIManager:show(ConfirmBox:new{
        text = T(_("Keep matching \"%1\" in the book text?\nThe AI keeps the old name either way — this only affects occurrence counts, search and highlight matching."), old_name),
        ok_text = _("Keep matching"),
        cancel_text = _("Stop matching"),
        cancel_callback = function()
            local ua = ActionCache.getUserAliases(book_file)
            local rec = ua[new_name]
            if type(rec) ~= "table" then
                rec = {}
                ua[new_name] = rec
            end
            rec.ignore = rec.ignore or {}
            for _idx, term in ipairs(rec.ignore) do
                if type(term) == "string" and term:lower() == old_name:lower() then return end
            end
            table.insert(rec.ignore, old_name)
            ActionCache.setUserAliases(book_file, ua)
            -- The open root menu shows counts built from the pre-ignore
            -- aliases; a reload picks the ignore up
            self_ref:reloadLiveMain(book_file)
        end,
    })
end

function XrayBrowser:editSearchTerms(item, category_key, item_title, source, nav_context)
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
                    item_name, captured_alias, is_user_added and "remove" or "ignore", nav_context)
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
                    item_name, captured_alias, "restore", nav_context)
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
                self_ref:_addSearchTermInput(item, category_key, item_title, source, item_name, nav_context)
            end,
        },
        {
            text = _("Close"),
            id = "close",
            callback = function()
                UIManager:close(self_ref._edit_dialog)
                self_ref._edit_dialog = nil
                -- Detail viewer already refreshed by each action; just close the dialog
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
--- @param nav_context table|nil Category navigation context
function XrayBrowser:_editSearchTermAction(item, category_key, item_title, source, item_name, alias, action, nav_context)
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

    -- Refresh item detail underneath to reflect updated search terms
    if self._detail_viewer then
        UIManager:close(self._detail_viewer)
        self._detail_viewer = nil
    end
    self:showItemDetail(item, category_key, item_title, source, nav_context)

    -- Re-open edit dialog to reflect changes
    self:editSearchTerms(item, category_key, item_title, source, nav_context)
end

--- Show input dialog to add a new search term
--- @param item table The item data
--- @param category_key string The category key
--- @param item_title string Display title
--- @param source table|nil Navigation source
--- @param item_name string The item display name (storage key)
--- @param nav_context table|nil Category navigation context
function XrayBrowser:_addSearchTermInput(item, category_key, item_title, source, item_name, nav_context)
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
                        self_ref:editSearchTerms(item, category_key, item_title, source, nav_context)
                    end,
                },
                {
                    text = _("Add"),
                    is_enter_default = true,
                    callback = function()
                        local new_alias = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if not new_alias or new_alias:match("^%s*$") then
                            self_ref:editSearchTerms(item, category_key, item_title, source, nav_context)
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
                                self_ref:editSearchTerms(item, category_key, item_title, source, nav_context)
                                return
                            end
                        end

                        -- Remove from ignore if it was previously ignored
                        for i = #entry.ignore, 1, -1 do
                            if entry.ignore[i]:lower() == new_lower then
                                table.remove(entry.ignore, i)
                            end
                        end

                        -- Save to storage
                        table.insert(entry.add, new_alias)
                        all_data[item_name] = entry
                        ActionCache.setUserAliases(self_ref.metadata.book_file, all_data)

                        -- Update in-memory
                        if type(item.aliases) ~= "table" then
                            item.aliases = item.aliases and { item.aliases } or {}
                        end
                        table.insert(item.aliases, new_alias)

                        -- Clear distribution cache
                        if self_ref._dist_cache then
                            self_ref._dist_cache[tostring(item)] = nil
                        end

                        -- Refresh item detail underneath to reflect new search term
                        if self_ref._detail_viewer then
                            UIManager:close(self_ref._detail_viewer)
                            self_ref._detail_viewer = nil
                        end
                        self_ref:showItemDetail(item, category_key, item_title, source, nav_context)

                        UIManager:show(Notification:new{
                            text = T(_("Added \"%1\""), new_alias),
                        })
                        -- Re-open edit dialog
                        self_ref:editSearchTerms(item, category_key, item_title, source, nav_context)
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

--- Build a FRESH book_metadata table for this artifact's book. Never mutate the
--- inherited table in place: the 2-level config copy shares it BY REFERENCE with
--- the module-level configuration, so writing through it permanently pairs this
--- book's file with another book's title/author (injection_gating_audit).
--- Existing fields are inherited only when the metadata already refers to THIS
--- book (it may carry the per-book AI metadata override and reading progress).
local function freshBookMetadata(existing, file, fallback_title, fallback_author)
    local meta = {}
    if existing and require("koassistant_doc_settings").samePath(existing.file, file) then
        for k, v in pairs(existing) do meta[k] = v end
    end
    meta.file = file
    meta.title = meta.title or fallback_title
    meta.author = meta.author or fallback_author or ""
    meta.author_clause = (meta.author ~= "") and (" by " .. meta.author) or ""
    return meta
end

--- Launch a highlight-context book chat with the given text
--- @param detail_text string The X-Ray detail text to discuss
function XrayBrowser:chatAboutItem(detail_text, entity)
    local Dialogs = require("koassistant_dialogs")  -- Lazy to avoid circular dep
    -- Refresh config from settings so provider/model changes since browser opened take effect
    if self.metadata.plugin and self.metadata.plugin.updateConfigFromSettings then
        self.metadata.plugin:updateConfigFromSettings()
    end
    -- Shallow-copy config and features to avoid mutating shared metadata
    local orig_config = self.metadata.configuration
    local config = {}
    for k, v in pairs(orig_config) do config[k] = v end
    config.features = {}
    for k, v in pairs(orig_config.features or {}) do config.features[k] = v end
    -- Clear context flags for highlight context (matches main.lua highlight pattern)
    config.features.is_general_context = nil
    config.features.is_book_context = nil
    config.features.is_library_context = nil
    -- Ensure book_metadata has the correct file for this artifact's book
    -- (may be stale if config was from a different book or file browser context)
    if self.metadata.book_file then
        config.features.book_metadata = freshBookMetadata(config.features.book_metadata,
            self.metadata.book_file, self.metadata.title, self.metadata.book_author)
    end
    -- Clear stale selection data - the "highlight" is AI-generated, not a real book selection,
    -- so "Save to Note" must be disabled (prevents saving to a random prior highlight position)
    config.features.selection_data = nil
    -- Set X-Ray chat pseudo-context flag (consumed once by showChatGPTDialog)
    -- Action filtering is now handled by the xray_chat input context sorting
    config.features._xray_chat_context = true
    config.features._hide_artifacts = true
    -- When no book is open, exclude actions that need document data (text extraction, annotations)
    if not self.ui or not self.ui.document then
        config.features._exclude_action_flags = {"use_book_text", "use_annotations"}
    end

    -- Pass X-Ray source framing as context prefix (injected before action prompt,
    -- not into text). Recon 2e (2026-08-16): name what the model is looking at —
    -- the old generic "analysis of the work" line never said this is an X-Ray
    -- ENTRY for a named entity, so replies treated the entry text as book prose.
    -- Model-facing string, deliberately untranslated (like its predecessor).
    local subject
    if entity and entity.name then
        subject = string.format('the X-Ray entry for "%s" (%s)',
            entity.name, entity.category or "entry")
    else
        subject = "an entry from the X-Ray"
    end
    local book_name = self.metadata.title
        and (' of "' .. self.metadata.title .. '"') or " of this book"
    local framing
    if self.scope then
        framing = "(Note: The following is " .. subject .. " from a Section X-Ray" .. book_name
            .. ' covering "' .. (self.scope.label or "") .. '" (' .. (self.scope.page_summary or "")
            .. "). It is AI-generated analysis, not text from the book itself.)"
    elseif not self.metadata.full_document and self.metadata.progress then
        framing = "(Note: The following is " .. subject .. " from an AI-generated X-Ray" .. book_name
            .. ", built at " .. self.metadata.progress .. " reading progress."
            .. " It is analysis, not text from the book itself.)"
    else
        framing = "(Note: The following is " .. subject .. " from an AI-generated X-Ray" .. book_name
            .. ". It is analysis, not text from the book itself.)"
    end
    config.features._xray_context_prefix = framing

    Dialogs.showChatGPTDialog(self.ui, detail_text, config, nil, self.metadata.plugin)
end

--- Generate an AI Wiki entry for an X-Ray item
--- @param item table The X-Ray item
--- @param category_key string The X-Ray category
--- @param title string Display title for re-opening detail view
--- @param source string|nil Source context for navigation
--- @param nav_context table|nil Navigation context for back/forward
function XrayBrowser:runWikiForItem(item, category_key, title, source, nav_context)
    local Dialogs = require("koassistant_dialogs")
    local Actions = require("prompts/actions")
    local ActionCache = require("koassistant_action_cache")

    local wiki_action = Actions.highlight.wiki
    if not wiki_action then return end

    local item_name = item.name or item.term or ""
    local file = self.metadata.book_file
    if not file then return end

    -- Refresh config from settings (same pattern as chatAboutItem)
    if self.metadata.plugin and self.metadata.plugin.updateConfigFromSettings then
        self.metadata.plugin:updateConfigFromSettings()
    end
    local orig_config = self.metadata.configuration
    local config = {}
    for k, v in pairs(orig_config) do config[k] = v end
    config.features = {}
    for k, v in pairs(orig_config.features or {}) do config.features[k] = v end
    -- Clear context flags for highlight context (wiki uses item name as highlighted_text)
    config.features.is_general_context = nil
    config.features.is_book_context = nil
    config.features.is_library_context = nil

    -- Ensure book_metadata has the correct file for this artifact's book
    if file then
        config.features.book_metadata = freshBookMetadata(config.features.book_metadata,
            file, self.metadata.title, self.metadata.book_author)
    end

    -- Set item description as disambiguation context (consumed by _forced_surrounding_context)
    config.features._forced_surrounding_context = XrayParser.formatItemDetail(item, category_key)

    local book_metadata = config.features.book_metadata
    local self_ref = self

    Dialogs.executeActionForResult(wiki_action, item_name, self.ui, config, self.metadata.plugin, book_metadata,
        function(result, metadata)
            -- Close stale item detail viewer (buttons reflect pre-generation state)
            if self_ref._detail_viewer then
                UIManager:close(self_ref._detail_viewer)
                self_ref._detail_viewer = nil
            end
            if result then
                ActionCache.setWikiEntry(file, category_key, item_name, result, metadata)
                local cached = ActionCache.getWikiEntry(file, category_key, item_name)
                -- Re-open item detail (fresh "View AI Wiki" button) with wiki on top
                self_ref:showItemDetail(item, category_key, title, source, nav_context)
                self_ref:showWikiViewer(item, category_key, cached, title, source, nav_context)
            else
                -- Error case: re-open item detail view
                self_ref:showItemDetail(item, category_key, title, source, nav_context)
            end
        end
    )
end

--- Show a cached wiki entry in a simple viewer with Delete/Regenerate
--- @param item table The X-Ray item
--- @param category_key string The X-Ray category
--- @param cached table The cached wiki entry from ActionCache
--- @param title string Display title for re-opening detail view
--- @param source string|nil Source context for navigation
--- @param nav_context table|nil Navigation context for back/forward
function XrayBrowser:showWikiViewer(item, category_key, cached, title, source, nav_context)
    local ChatGPTViewer = require("koassistant_chatgptviewer")
    local ActionCache = require("koassistant_action_cache")
    local item_name = item.name or item.term or ""
    local file = self.metadata.book_file
    local self_ref = self

    local wiki_key = ActionCache.WIKI_PREFIX .. category_key .. ":" .. item_name
    local wiki_title = T(_("AI Wiki: %1"), item_name)
    if cached.timestamp then
        local rel = Constants.formatRelativeTime(cached.timestamp)
        if rel ~= "" then
            wiki_title = wiki_title .. " · " .. rel
        end
    end
    local wiki_viewer = ChatGPTViewer:new{
        title = wiki_title,
        text = cached.result,
        simple_view = true,
        cache_type_name = _("AI Wiki"),
        on_regenerate = function()
            self_ref:runWikiForItem(item, category_key, title, source, nav_context)
        end,
        regenerate_label = _("Regenerate"),
        on_delete = function()
            ActionCache.clearWikiEntry(file, category_key, item_name)
            -- Close stale item detail viewer before re-opening with fresh button state
            if self_ref._detail_viewer then
                UIManager:close(self_ref._detail_viewer)
                self_ref._detail_viewer = nil
            end
            self_ref:showItemDetail(item, category_key, title, source, nav_context)
            UIManager:show(Notification:new{
                text = _("AI Wiki deleted"),
                timeout = 2,
            })
        end,
        _book_open = self.ui and self.ui.document ~= nil,
        _plugin = self.metadata.plugin,
        _artifact_file = file,
        _artifact_key = wiki_key,
        _artifact_book_title = self.metadata.title,
        _artifact_book_author = self.metadata.author,
        on_launch_chat = self.metadata.plugin and self.metadata.plugin._buildLaunchChatCallback
            and self.metadata.plugin:_buildLaunchChatCallback(file, self.metadata.title, self.metadata.author, cached.result, _("AI Wiki")) or nil,
    }
    UIManager:show(wiki_viewer)
end


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
    -- Log-scaled fill: mention counts are heavy-tailed, and the linear ratio
    -- collapsed every count under max/width into the same one-block bar
    -- (device 2026-08-17: 75 and 5 rendered identically next to a dominant
    -- max). Log keeps the fill monotone in count, so parent roll-ups still
    -- dominate in the appearances tree.
    local filled = math.max(1, math.floor(
        bar_width * math.log(count + 1) / math.log(max_count + 1) + 0.5))
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

    -- Get hierarchical TOC (all depths), gated by the posture-routed spoiler gate (F2)
    local picker_gate = self:_spoilerGate()
    local entries, max_depth = getHierarchicalChapters(self.ui, picker_gate, self.scope)
    if not entries or #entries == 0 then
        -- Fallback: page-range chunks (flat, no hierarchy)
        local chunks = getAllPageRangeChapters(self.ui, picker_gate)
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
        -- Dim: unread (spoiler) or out_of_scope (section boundary)
        local is_dim = false
        if self.scope then
            is_dim = entry.out_of_scope and not self._scope_reveal_warned
        else
            is_dim = entry.unread and not self._mentions_spoiler_warned
        end
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
            out_of_scope = entry.out_of_scope,
            dim = is_dim,
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

    -- Prepend scope/document options
    if self.scope then
        -- Section X-Ray: "Entire section" is the primary scope, plus "Entire document" reveal
        table.insert(collapsed_toc, 1, {
            text = T(_("Entire section (%1)"), self.scope.page_summary or ""),
            bold = current_chapter == "all",
            _is_all_chapters = true,
        })
        table.insert(collapsed_toc, 2, {
            text = _("Entire document"),
            bold = current_chapter == "all_reveal",
            dim = not self._scope_reveal_warned,
            separator = true,
            _is_all_reveal = true,
        })
    elseif not picker_gate then
        -- No spoiler gate (protection off, incl. finished/research) — one option
        table.insert(collapsed_toc, 1, {
            text = _("Entire document"),
            bold = current_chapter == "all" or current_chapter == "all_reveal",
            separator = true,
            _is_all_chapters = true,
        })
    else
        -- Two options: scoped (spoiler-safe, to reading position) and reveal-all
        table.insert(collapsed_toc, 1, {
            text = T(_("Entire document (to p. %1)"), picker_gate),
            bold = current_chapter == "all",
            _is_all_chapters = true,
        })
        table.insert(collapsed_toc, 2, {
            text = _("Entire document"),
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
            local warned = self_ref.scope and self_ref._scope_reveal_warned or self_ref._mentions_spoiler_warned
            if not warned then
                local warn_text = self_ref.scope
                    and _("This will scan beyond this Section X-Ray's scope.\n\nReveal all mentions?")
                    or _("This will scan beyond your X-Ray coverage.\n\nReveal all mentions?")
                self_ref._spoiler_dialog = ButtonDialog:new{
                    text = warn_text,
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
                                if self_ref.scope then
                                    self_ref._scope_reveal_warned = true
                                else
                                    self_ref._mentions_spoiler_warned = true
                                end
                                selectChapter("all_reveal")
                            end,
                        }},
                    },
                }
                UIManager:show(self_ref._spoiler_dialog)
            else
                selectChapter("all_reveal")
            end
        elseif item.out_of_scope then
            if not self_ref._scope_reveal_warned then
                self_ref._spoiler_dialog = ButtonDialog:new{
                    text = _("This chapter is outside this Section X-Ray's scope.\n\nReveal mentions?"),
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
                                self_ref._scope_reveal_warned = true
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

    -- "Entire document/section" at top
    if self.scope then
        table.insert(items, {
            text = T(_("Entire section (%1)"), self.scope.page_summary or ""),
            bold = current_chapter == "all",
            _is_all_chapters = true,
        })
        table.insert(items, {
            text = _("Entire document"),
            bold = current_chapter == "all_reveal",
            dim = not self._scope_reveal_warned,
            separator = true,
            _is_all_reveal = true,
        })
    else
        local flat_gate = self:_spoilerGate()
        if not flat_gate then
            -- No spoiler gate (protection off, incl. finished/research)
            table.insert(items, {
                text = _("Entire document"),
                bold = current_chapter == "all" or current_chapter == "all_reveal",
                separator = true,
                _is_all_chapters = true,
            })
        else
            table.insert(items, {
                text = T(_("Entire document (to p. %1)"), flat_gate),
                bold = current_chapter == "all",
                _is_all_chapters = true,
            })
            table.insert(items, {
                text = _("Entire document"),
                bold = current_chapter == "all_reveal",
                dim = not self._mentions_spoiler_warned,
                separator = true,
                _is_all_reveal = true,
            })
        end
    end

    -- Page-range chunks
    for _idx, ch in ipairs(chunks) do
        local is_dim = false
        if self.scope then
            is_dim = ch.out_of_scope and not self._scope_reveal_warned
        else
            is_dim = ch.unread and not self._mentions_spoiler_warned
        end
        table.insert(items, {
            text = ch.title or "",
            mandatory = ch.start_page,
            mandatory_dim = true,
            dim = is_dim,
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
            local warned = self_ref.scope and self_ref._scope_reveal_warned or self_ref._mentions_spoiler_warned
            if not warned then
                local warn_text = self_ref.scope
                    and _("This will scan beyond this Section X-Ray's scope.\n\nReveal all mentions?")
                    or _("This will scan beyond your X-Ray coverage.\n\nReveal all mentions?")
                self_ref._spoiler_dialog = ButtonDialog:new{
                    text = warn_text,
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
                                if self_ref.scope then
                                    self_ref._scope_reveal_warned = true
                                else
                                    self_ref._mentions_spoiler_warned = true
                                end
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
            if ch.out_of_scope then
                if not self_ref._scope_reveal_warned then
                    self_ref._spoiler_dialog = ButtonDialog:new{
                        text = _("This chapter is outside this Section X-Ray's scope.\n\nReveal mentions?"),
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
                                    self_ref._scope_reveal_warned = true
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
            elseif ch.unread then
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

    -- Section X-Rays: default to entire scope instead of current chapter.
    -- A book marked Finished likewise defaults to the whole book (B030):
    -- the gate already stands down for it, so the chapter default would
    -- only hide the rest behind one more tap.
    if chapter == nil and self.scope then
        chapter = "all"
    elseif chapter == nil then
        local BookSettings = require("koassistant_book_settings")
        local SafeDocSettings = require("koassistant_doc_settings")
        local ds = SafeDocSettings.resolve(self.metadata and self.metadata.book_file, self.ui)
        local features = self.metadata and self.metadata.configuration
            and self.metadata.configuration.features
        if BookSettings.resolveSpoilerPosture(ds, features).reason == "finished" then
            chapter = "all"
        end
    end

    -- Determine notification text
    local is_all = (chapter == "all" or chapter == "all_reveal")
    local notif_text = is_all and _("Analyzing book…") or _("Analyzing chapter…")
    UIManager:show(Notification:new{ text = notif_text })

    local self_ref = self
    UIManager:scheduleIn(0.2, function()
        local text, chapter_title
        local display_chapter = chapter  -- track what we're showing for the picker
        local mentions_gate = self_ref:_spoilerGate()  -- F2: posture-routed, position-strict

        -- Gate-crossing chapter clip (device round 2026-08-15): the chapter
        -- the reader is INSIDE crosses the gate — this surface used to
        -- extract its WHOLE span (the tree and the per-entity mention pages
        -- already clipped), so just entering chapter N revealed every entity
        -- in its unread tail. Clip the extraction at the gate page; the
        -- session-level reveal flag (_mentions_spoiler_warned, same one the
        -- picker's beyond-gate confirm sets) lifts the clip.
        local clipped_to
        local function gatedChapterText(ch)
            if mentions_gate and not self_ref._mentions_spoiler_warned
                    and ch.start_page and ch.start_page <= mentions_gate
                    and (ch.end_page or 0) > mentions_gate then
                clipped_to = mentions_gate
                return self_ref:_getChapterText({
                    title = ch.title,
                    start_page = ch.start_page,
                    end_page = mentions_gate,
                    depth = ch.depth,
                }), ch.title or ""
            end
            return self_ref:_getChapterText(ch), ch.title or ""
        end

        if is_all then
            -- Aggregate: page range depends on context
            -- Section X-Ray "all" = scope bounds; main X-Ray "all" = the
            -- spoiler gate (reading position; whole book when protection off)
            -- "all_reveal" = entire book
            local total_pages = self_ref.ui.document.info.number_of_pages or 0
            if total_pages == 0 then
                UIManager:show(InfoMessage:new{
                    text = _("Could not determine book length."),
                    timeout = 3,
                })
                return
            end
            local start_page = 1
            local end_page
            if self_ref.scope and chapter ~= "all_reveal" then
                -- Section X-Ray: scope bounds
                start_page = self_ref.scope_start or 1
                end_page = self_ref.scope_end or total_pages
            elseif chapter == "all_reveal" then
                end_page = total_pages
            else
                end_page = mentions_gate or total_pages
            end
            local all_chapter = { start_page = start_page, end_page = end_page }
            text = self_ref:_getChapterText(all_chapter)
            chapter_title = ""
        elseif type(chapter) == "table" then
            -- Specific chapter from picker
            text, chapter_title = gatedChapterText(chapter)
        else
            -- Current chapter (default — deepest TOC match; flat page chunk
            -- when there is no TOC)
            local cur = getChapterBoundaries(self_ref.ui, nil)
                or getPageRangeChapter(self_ref.ui)
            if cur then
                text, chapter_title = gatedChapterText(cur)
            else
                text, chapter_title = getCurrentChapterText(self_ref.ui, nil, self_ref)
            end
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

        -- Build menu items
        local items = {}

        -- Chapter picker button at top
        local picker_label
        local chapter_depth = type(chapter) == "table" and chapter.depth or nil
        if is_all then
            if self_ref.scope and chapter ~= "all_reveal" then
                picker_label = T(_("Entire section (%1) ▾"), self_ref.scope.page_summary or "")
            elseif chapter == "all_reveal" or not mentions_gate then
                picker_label = _("Entire document ▾")
            else
                picker_label = T(_("To p. %1 ▾"), mentions_gate)
            end
        elseif chapter_title and chapter_title ~= "" then
            picker_label = clipped_to
                and T(_("%1 (up to p. %2) ▾"), chapter_title, clipped_to)
                or (chapter_title .. " ▾")
        else
            picker_label = clipped_to
                and T(_("This Chapter (up to p. %1) ▾"), clipped_to)
                or _("This Chapter ▾")
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

        -- Reveal row while the span is clipped: one confirm, then this
        -- session's Mentions views show unclipped (same flag the picker's
        -- beyond-gate confirm sets)
        if clipped_to then
            table.insert(items, {
                text = _("Show the whole chapter…"),
                mandatory = _("may contain spoilers"),
                mandatory_dim = true,
                callback = function()
                    self_ref._spoiler_dialog = ButtonDialog:new{
                        text = _("The rest of this chapter is beyond your reading position.\n\nReveal mentions?"),
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
                                    self_ref:navigateBack()
                                    self_ref:showMentions(chapter)
                                end,
                            }},
                        },
                    }
                    UIManager:show(self_ref._spoiler_dialog)
                end,
            })
        end

        if #found == 0 then
            -- No results: show picker with empty-state message so user can try other chapters
            table.insert(items, {
                text = _("No X-Ray items found in this text."),
                dim = true,
            })
        end

        -- Build nav entries for prev/next navigation in detail view
        local nav_entries = {}
        for _idx, entry in ipairs(found) do
            table.insert(nav_entries, {
                item = entry.item,
                category_key = entry.category_key,
                name = XrayParser.getItemName(entry.item, entry.category_key),
            })
        end

        -- Item list — with comparison bars (round 5): counts normalized to
        -- the list max, so relative presence in this scope reads at a glance
        local max_count = 0
        for _idx, entry in ipairs(found) do
            if entry.count > max_count then max_count = entry.count end
        end
        local count_width = #tostring(max_count)
        for _idx, entry in ipairs(found) do
            local nav_entry = nav_entries[_idx]
            local short_cat = CHAPTER_CATEGORY_SHORT[entry.category_key] or entry.category_label
            local captured_idx = _idx
            table.insert(items, {
                text = nav_entry.name,
                -- No mandatory_dim here (round 10): this column carries the
                -- comparison HISTOGRAM, and graying it out grayed the bars —
                -- normal ink for this view, unlike the plain-info columns of
                -- the other lists
                mandatory = string.format("[%s] %s", short_cat,
                    buildDistributionBar(entry.count, max_count, 6, count_width)),
                callback = function()
                    self_ref:showItemDetail(nav_entry.item, nav_entry.category_key, nav_entry.name, nil, {
                        entries = nav_entries, index = captured_idx,
                    })
                end,
            })
        end

        -- Title: just "Mentions (N)" — the scope already lives in the picker
        -- row right below, naming it twice cramped the title bar (round 5).
        -- Two-line rows: a long chapter name in the picker row wraps instead
        -- of truncating its "▾" away (device round 2026-08-13)
        self_ref:navigateForward(T(_("Mentions (%1)"), #found), items, nil, {
            single_line = false,
            multilines_forced = true,
            items_max_lines = 2,
        })
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

        -- Build nav entries for prev/next navigation in detail view
        local nav_entries = {}
        for _idx, entry in ipairs(found) do
            table.insert(nav_entries, {
                item = entry.item,
                category_key = entry.category_key,
                name = XrayParser.getItemName(entry.item, entry.category_key),
            })
        end

        local items = {}
        for _idx, entry in ipairs(found) do
            local nav_entry = nav_entries[_idx]
            local short_cat = CHAPTER_CATEGORY_SHORT[entry.category_key] or entry.category_label
            local captured_idx = _idx
            table.insert(items, {
                text = nav_entry.name,
                mandatory = string.format("[%s] %s", short_cat, T(_("%1x"), entry.count)),
                mandatory_dim = true,
                callback = function()
                    self_ref:showItemDetail(nav_entry.item, nav_entry.category_key, nav_entry.name, nil, {
                        entries = nav_entries, index = captured_idx,
                    })
                end,
            })
        end

        local title
        if chapter.title and chapter.title ~= "" then
            title = T(_("%1: %2 mentions"), chapter.title, #found)
        else
            title = T(_("Chapter: %1 mentions"), #found)
        end

        self_ref:navigateForward(title, items)
    end)
end

--- Build the Chapter Appearances tree and display it (slice 4 + TOC-mimic
--- round, ref #78): the full TOC hierarchy in KOReader's OWN TOC shape —
--- expand/collapse arrows on parent rows (left-zone tap toggles, readertoc
--- idiom via the shared menu's onMenuSelect wrap), no arrows on terminal
--- nodes, top level collapsed on entry with the reader's current chain
--- auto-expanded, the current node BOLD — with a mention count + histogram
--- bar at the end of every row, powered by the one gatherMentionHits pass
--- (counts and mention lists consistent by construction). Stock-TOC row
--- styling: single truncated lines, dotted leaders to the histogram, no
--- divider lines (round 9). Bars normalize GLOBALLY (monotone: a bigger
--- count is never a shorter bar; parents are roll-ups so theirs dominate).
--- Spoiler gating is DISPLAY-only: all hits are in memory; concealed rows
--- show "···" until revealed (instant flip, one-time confirm; revealing a
--- parent reveals its subtree), a node whose span crosses the gate shows
--- its count clipped at the gate.
--- @param item table The X-Ray item
--- @param category_key string Category key
--- @param item_title string Display name for the item
--- @param data table Mutable distribution state {nodes, hits, gate, revealed, expanded, ...}
--- @param is_refresh boolean If true, update menu in-place; if false, navigateForward
function XrayBrowser:_buildDistributionView(item, category_key, item_title, data, is_refresh, detail_context)
    local self_ref = self
    local nodes = data.nodes
    local gate = data.gate

    -- Tree row metrics (round 8): our compact 20-row default, or the
    -- reader's own KOReader ToC settings when opted in — screens vary too
    -- much for one number to be right everywhere, but most users never
    -- touch KOReader's ToC density, so following it by default would undo
    -- the compact look
    local br_features = (self.metadata and self.metadata.configuration
        and self.metadata.configuration.features) or {}
    local tree_perpage = TREE_PERPAGE
    local tree_font
    if br_features.xray_appearances_rows == "follow_toc" then
        tree_perpage = G_reader_settings:readSetting("toc_items_per_page") or 14
        tree_font = G_reader_settings:readSetting("toc_items_font_size")
            or Menu.getItemFontSize(tree_perpage)
    else
        tree_font = Menu.getItemFontSize(tree_perpage)
    end

    -- Anything still concealed? (unrevealed beyond-gate/out-of-scope rows,
    -- or an unrevealed node whose span CROSSES the gate — its tail is hidden)
    local concealed = false
    for i, n in ipairs(nodes) do
        if not data.revealed[i] then
            if n.unread or n.out_of_scope then
                concealed = true
                break
            end
            if gate and n.start_page <= gate and n.end_page > gate then
                concealed = true
                break
            end
        end
    end

    local items = {}

    -- "All appearances" (rounds 4–5): door to the whole-book mention list —
    -- count on the right, the spoiler clip in parentheses. Complete (no
    -- gate, or everything revealed) → unclipped. Not on section browsers
    -- (their scope is the boundary; the rows already cover it).
    if not self.scope then
        local fully = (not gate) or not concealed
        table.insert(items, {
            text = fully and _("All appearances")
                or T(_("All appearances (up to p. %1)"), gate),
            bold = true,
            mandatory = tostring((fully and data.total_full or data.total_gated) or 0),
            mandatory_dim = true,
            callback = function()
                self_ref:_showChapterMentions(item, category_key, item_title, nil,
                    { hits = data.hits, no_clip = fully or nil })
            end,
        })
    end

    -- Reveal-all row while anything is concealed (counts are already in
    -- memory — this is a display flip, not a scan)
    if concealed then
        table.insert(items, {
            text = self.scope and _("Reveal beyond scope") or _("Reveal all chapters"),
            mandatory = self.scope and _("outside section scope") or _("may contain spoilers"),
            mandatory_dim = true,
            bold = true,
            callback = function()
                for j = 1, #nodes do
                    data.revealed[j] = true
                end
                data.spoiler_warned = true
                data._focus_idx = nil
                self_ref:_buildDistributionView(item, category_key, item_title, data, true)
            end,
        })
    end
    if #items > 0 then items[#items].separator = true end

    -- Expand/collapse machinery (only when the TOC actually has parents) —
    -- the readertoc prototypes: one expand + one collapse button, items get
    -- an instance as their state widget; the shared menu's onMenuSelect wrap
    -- routes left-zone taps to state.callback(index)
    local has_parents = false
    for i, n in ipairs(nodes) do
        if n._is_parent then
            has_parents = true
            break
        end
    end
    local expand_proto, collapse_proto
    local button_width = 0
    if has_parents then
        local Button = require("ui/widget/button")
        local BD = require("ui/bidi")
        local icon_size = math.floor(Screen:getHeight() / tree_perpage * 2 / 5)
        button_width = icon_size * 2
        local function toggleNode(idx)
            if not idx then return end
            if data.expanded[idx] then
                data.expanded[idx] = nil
            else
                data.expanded[idx] = true
            end
            data._focus_idx = idx
            self_ref:_buildDistributionView(item, category_key, item_title, data, true)
        end
        expand_proto = Button:new{
            icon = "control.expand",
            icon_rotation_angle = BD.mirroredUILayout() and 180 or 0,
            width = button_width,
            icon_width = icon_size,
            icon_height = icon_size,
            bordersize = 0,
            show_parent = self.menu,
            callback = toggleNode,
            onTapSelectButton = function() end, -- pass through to onMenuSelect
        }
        collapse_proto = Button:new{
            icon = "control.collapse",
            width = button_width,
            icon_width = icon_size,
            icon_height = icon_size,
            bordersize = 0,
            show_parent = self.menu,
            callback = toggleNode,
            onTapSelectButton = function() end, -- pass through to onMenuSelect
        }
    end

    -- Visible set under the expand/collapse state (a node shows only while
    -- every ancestor is expanded)
    local visible = {}
    do
        local skip_deeper_than
        for i, n in ipairs(nodes) do
            local d = n.depth or 1
            if skip_deeper_than and d > skip_deeper_than then
                -- inside a collapsed subtree
            else
                skip_deeper_than = nil
                table.insert(visible, i)
                if n._is_parent and not data.expanded[i] then
                    skip_deeper_than = d
                end
            end
        end
    end

    -- Display counts + GLOBAL bar maximum over ALL nodes (visible or not, so
    -- bars keep their meaning across expand/collapse; reveals can raise it,
    -- like the old scan did)
    local shown_counts = {}
    local hidden_flags = {}
    local overall_max = 0
    for i, n in ipairs(nodes) do
        local hidden = (n.unread or n.out_of_scope) and not data.revealed[i]
        hidden_flags[i] = hidden
        if not hidden then
            local shown = data.revealed[i] and n.count or n.gated_count or n.count
            shown_counts[i] = shown
            if shown > overall_max then overall_max = shown end
        end
    end
    local count_width = overall_max > 0 and #tostring(overall_max) or 1

    -- Bold = the deepest VISIBLE node containing the reading position (the
    -- KOReader TOC current-entry idiom; collapsed deeper levels bold their
    -- visible ancestor)
    local bold_idx
    local best_depth = -1
    for _v, i in ipairs(visible) do
        local n = nodes[i]
        if n.is_current and (n.depth or 1) >= best_depth then
            best_depth = n.depth or 1
            bold_idx = i
        end
    end

    -- Indent unit: width of 4 spaces (the hierarchical picker idiom),
    -- measured at the tree's own row font
    local indent_unit = 0
    if (data.max_depth or 0) > 1 then
        local Font = require("ui/font")
        local TextWidget = require("ui/widget/textwidget")
        local tmp = TextWidget:new{
            text = "    ",
            face = Font:getFace("smallinfofont", tree_font),
        }
        indent_unit = tmp:getSize().w
        tmp:free()
    end

    local node_to_item = {}
    for _v, i in ipairs(visible) do
        local n = nodes[i]
        local captured_i = i
        local node_title = n.title
        if not node_title or node_title == "" then
            node_title = T(_("Page %1"), n.start_page)
        end
        local st
        if n._is_parent and expand_proto then
            st = (data.expanded[i] and collapse_proto or expand_proto):new{}
        end
        node_to_item[i] = #items + 1
        if hidden_flags[i] then
            -- Concealed: dimmed, tap to reveal (one-time confirm); revealing
            -- a parent reveals its subtree — the consent covers the span.
            -- The arrow still expands without revealing (titles are TOC
            -- data, never gated — only counts are)
            table.insert(items, {
                text = node_title,
                indent = indent_unit * ((n.depth or 1) - 1),
                state = st,
                index = i,
                mandatory = "···",
                mandatory_dim = true,
                dim = true,
                callback = function()
                    local function do_reveal()
                        data.revealed[captured_i] = true
                        for j = captured_i + 1, #nodes do
                            if (nodes[j].depth or 1) <= (n.depth or 1) then break end
                            data.revealed[j] = true
                        end
                        data._focus_idx = captured_i
                        self_ref:_buildDistributionView(item, category_key, item_title, data, true)
                    end
                    if not data.spoiler_warned then
                        local warn_text = self_ref.scope
                            and _("This chapter is outside this Section X-Ray's scope.\n\nReveal mentions?")
                            or _("This chapter is beyond your reading position and may contain spoilers.\n\nReveal mentions?")
                        local confirm_dialog
                        confirm_dialog = ButtonDialog:new{
                            text = warn_text,
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
            local shown = shown_counts[i] or 0
            table.insert(items, {
                text = node_title,
                bold = (i == bold_idx) or nil,
                indent = indent_unit * ((n.depth or 1) - 1),
                state = st,
                index = i,
                mandatory = buildDistributionBar(shown, overall_max, nil, count_width),
                mandatory_dim = (shown == 0),
                callback = function()
                    if shown > 0 then
                        -- Mention list scoped to this node's span; a node the
                        -- user revealed opens unclipped
                        self_ref:_showChapterMentions(item, category_key, item_title, n,
                            { hits = data.hits,
                              no_clip = data.revealed[captured_i] or nil })
                    else
                        UIManager:show(Notification:new{
                            text = T(_("No X-Ray items in \"%1\"."),
                                n.title or _("this chapter")),
                        })
                    end
                end,
            })
        end
    end
    -- Convert focus from node index to row index (accounts for header rows;
    -- a toggled-collapsed target still maps — it stays visible itself)
    if data._focus_idx and node_to_item[data._focus_idx] then
        data._focus_idx = node_to_item[data._focus_idx]
    end

    -- Name-only title (the round-5 truncation rule); the All row carries the
    -- total
    local title = item_title

    if is_refresh then
        -- Update menu in-place, preserving scroll position
        self.current_title = title
        self:_switchMenuItems(title, items, data._focus_idx)
    else
        -- The stock-TOC look (maintainer round 9): single truncated lines,
        -- dotted leaders running to the histogram, no divider lines; denser
        -- rows than the rest of the browser (round 10), font from KOReader's
        -- own perpage→size mapping
        self:navigateForward(title, items, data._focus_idx, {
            single_line = true,
            with_dots = true,
            align_baselines = true,
            line_color = require("ffi/blitbuffer").COLOR_WHITE,
            state_w = has_parents and button_width or nil,
            items_per_page = tree_perpage,
            items_font_size = tree_font,
            items_mandatory_font_size = tree_font - 4,
        })
        -- Stash item detail info so back from distribution reopens the TextViewer
        local top = self.nav_stack[#self.nav_stack]
        if top then
            top.reopen_detail = {
                item = item,
                category_key = category_key,
                title = item_title,
                source = detail_context and detail_context.source,
                nav_context = detail_context and detail_context.nav_context,
            }
        end
        -- Close the item detail TextViewer now that distribution is ready underneath
        if detail_context and detail_context.dismiss_viewer then
            self:_dismissDetail(detail_context.dismiss_viewer)
        end
    end

    -- Search-return chain (round 4): reopen the mention page the user came
    -- from, one stack level above the freshly built distribution
    if not is_refresh and XrayBrowser._pending_mentions then
        local pm = XrayBrowser._pending_mentions
        XrayBrowser._pending_mentions = nil
        if not pm.book_file or pm.book_file == self.metadata.book_file then
            local target_chapter
            if not pm.whole_book and pm.chapter_start_page then
                for _idx, n in ipairs(nodes) do
                    if n.start_page == pm.chapter_start_page
                        and (not pm.chapter_title or n.title == pm.chapter_title)
                        and (not pm.chapter_depth or (n.depth or 1) == pm.chapter_depth) then
                        target_chapter = n
                        break
                    end
                end
                -- Chapter no longer found (rebuilt data): stay on distribution
                if not target_chapter then pm = nil end
            end
            if pm then
                self:_showChapterMentions(item, category_key, item_title, target_chapter,
                    { hits = data.hits, no_clip = pm.no_clip or nil })
            end
        end
    end
end

--- Return-info shape for the floating "Back to X-Ray" button (reopens the
--- browser at this entity's distribution view).
function XrayBrowser:_mentionReturnInfo(category_key, item_title)
    local return_info = {
        ui = self.ui,
        plugin_ref = self.metadata and self.metadata.plugin,
        category_key = category_key,
        item_name = item_title,
    }
    if self.scope then return_info.scope = self.scope end
    return return_info
end

--- THE text-matching spoiler gate (F2, slice 4): routed through the posture
--- resolver, so research mode, a finished book, and the global/book spoiler
--- settings all govern it — protection off means NO gating anywhere in the
--- distribution/mention surfaces. Under protection the gate is
--- max(INSTALLED X-Ray coverage, reading position) — the installed
--- artifact's content already reveals through its coverage (maintainer
--- 2026-08-13: an entry can say "dies in chapter 12", so gating the
--- appearance surfaces below the version the reader chose to install
--- protects nothing), and a reader flipping BACK to re-read must not lose
--- spans they have already read. A complete install reveals everything.
--- nil = no gating. Section browsers return nil — scope replaces spoiler
--- gating (picking the section was the consent).
function XrayBrowser:_spoilerGate()
    local ui = self.ui
    if not (ui and ui.document) then return nil end
    if self.scope then return nil end
    local BookSettings = require("koassistant_book_settings")
    local SafeDocSettings = require("koassistant_doc_settings")
    local ds = SafeDocSettings.resolve(self.metadata and self.metadata.book_file, ui)
    local features = self.metadata and self.metadata.configuration
        and self.metadata.configuration.features
    if not BookSettings.resolveSpoilerFree(ds, features) then return nil end
    local md = self.metadata
    if md and md.full_document then return nil end
    local total = ui.document.info and ui.document.info.number_of_pages
    local gate = getCurrentPage(ui) or 0
    if total and md and md.progress_decimal then
        local coverage = math.floor(md.progress_decimal * total + 0.5)
        if coverage > gate then gate = coverage end
    end
    if gate == 0 or (total and gate >= total) then return nil end
    return gate
end

--- Mention list (xray_marking_plan.md slices 1+4, ref #78): one row per
--- occurrence — page + bold-match context snippet (the exact PTF shape
--- KOReader's own search all-results list renders, ellipsized), readable IN
--- PLACE without touching the book position. Lives IN the browser stack:
--- lower-left up-arrow returns to Chapter Appearances, the hamburger stays
--- the browser's own. Tap = jump to THAT hit and enter the native search
--- session there (built-in highlighting + prev/next — no custom overlay,
--- maintainer verdict). chapter = nil → whole book. Spans are clipped by
--- the posture-routed spoiler gate (_spoilerGate) unless opts.no_clip (the
--- user revealed this span, or protection is off). opts.hits = the
--- distribution's pre-gathered hit list (one pass powers counts AND these
--- rows — consistent by construction); absent → gather here.
function XrayBrowser:_showChapterMentions(item, category_key, item_title, chapter, opts)
    local self_ref = self
    local ui = self.ui
    if not (ui and ui.document) then return end
    local terms = collectSearchTerms(item, item_title)
    if #terms == 0 then return end
    local pre_hits = opts and opts.hits
    if not pre_hits and not ui.document.findAllText then return end
    local no_clip = opts and opts.no_clip

    local function render(all_hits)
        -- Span bounds: the chapter's page range, or the whole book — either
        -- way clipped at the spoiler gate unless no_clip
        local boundary = (not no_clip) and self_ref:_spoilerGate() or nil
        local first_page, last_page
        if chapter then
            first_page = chapter.start_page
            last_page = chapter.end_page
            if boundary and boundary < last_page then
                -- Crossing span: show up to the gate (an entirely-beyond
                -- span yields an empty list — reveal is the way in)
                last_page = math.max(boundary, first_page - 1)
            else
                boundary = nil  -- no visible clip on this span
            end
        else
            first_page = 1
            last_page = boundary
                or (ui.document.info and ui.document.info.number_of_pages)
        end
        if not (first_page and last_page) then return end

        local mentions = {}
        for _idx, m in ipairs(all_hits) do
            if m.display_page and m.display_page >= first_page
                and m.display_page <= last_page then
                table.insert(mentions, m)
            end
        end

        -- Return descriptor: the search-return button relaunches THIS page
        local mentions_state = {
            whole_book = (not chapter) or nil,
            chapter_start_page = chapter and chapter.start_page or nil,
            chapter_title = chapter and chapter.title or nil,
            chapter_depth = chapter and chapter.depth or nil,
            no_clip = no_clip or nil,
        }
        local list_items = {}
        for _i, m in ipairs(mentions) do
            local captured = m
            table.insert(list_items, {
                text = m.row_text,
                mandatory = T(_("p. %1"), m.display_page),
                mandatory_dim = true,
                callback = function()
                    self_ref:_gotoMentionAndSearch(category_key, item_title,
                        captured, terms, mentions_state)
                end,
            })
        end
        if #mentions == 0 then
            table.insert(list_items, {
                text = _("No exact text matches in this scope."),
                dim = true,
                callback = function() end,
            })
        end

        -- Scope + count as a header LINE above the entries (round 5: the
        -- menu title truncates — it carries only the entity name now)
        local scope_line
        if chapter and boundary then
            scope_line = T(_("%1 (up to p. %2) — %3 mentions"),
                chapter.title or _("Chapter"), boundary, #mentions)
        elseif chapter then
            scope_line = T(_("%1 — %2 mentions"),
                chapter.title or _("Chapter"), #mentions)
        elseif boundary then
            scope_line = T(_("Whole book (up to p. %1) — %2 mentions"),
                boundary, #mentions)
        else
            scope_line = T(_("Whole book — %1 mentions"), #mentions)
        end
        table.insert(list_items, 1, {
            text = scope_line,
            bold = true,
            dim = true,
            separator = true,
            callback = function() end,
        })

        -- In the browser stack (round 4): lower-left up-arrow returns to
        -- Chapter Appearances, the hamburger stays the browser's own; the
        -- menu flips to multiline for the PTF bold-match snippets and flips
        -- back on navigate-back
        self_ref:navigateForward(item_title, list_items, nil, {
            single_line = false,
            multilines_forced = true,
            items_max_lines = 3,
        })
    end

    if pre_hits then
        render(pre_hits)
    else
        UIManager:show(Notification:new{ text = _("Finding mentions…") })
        UIManager:scheduleIn(0.1, function()
            render(gatherMentionHits(ui, terms))
        end)
    end
end

--- Jump to one mention and enter KOReader's native search session there —
--- the built-in search owns hit highlighting and prev/next navigation; the
--- floating "Back to X-Ray" button restores the ORIGIN reading position and
--- leads back to the mention page (round 4 points 5+6); reading on instead
--- keeps the new place deliberately. Location-stack snapshot too, so the
--- native back gesture also undoes the jump (A8, ref #78).
function XrayBrowser:_gotoMentionAndSearch(category_key, item_title, mention, terms, mentions_state)
    local ui = self.ui
    if not (ui and ui.document and ui.search) then return end
    -- Origin BEFORE anything moves: the return button jumps back here
    local origin
    if ui.document.info and ui.document.info.has_pages then
        origin = { page = ui.view and ui.view.state and ui.view.state.page or 1 }
    else
        origin = { xp = (ui.rolling and ui.rolling.getLastProgress
            and ui.rolling:getLastProgress()) or ui.document:getXPointer() }
    end
    -- Reveal the page: covering widgets, then the browser
    if self._cleanup_widgets then
        for _cw, widget in ipairs(self._cleanup_widgets) do
            UIManager:close(widget)
        end
    end
    if self.menu then UIManager:close(self.menu) end
    if ui.link and ui.link.addCurrentLocationToStack then
        ui.link:addCurrentLocationToStack()
    end
    if mention.xp then
        ui:handleEvent(Event:new("GotoXPointer", mention.xp, mention.xp))
    elseif mention.page then
        ui:handleEvent(Event:new("GotoPage", mention.page))
    end
    local return_info = self:_mentionReturnInfo(category_key, item_title)
    return_info.origin = origin
    return_info.mentions_state = mentions_state
    if ui.document.info and ui.document.info.has_pages then
        -- PDF: no regex support — search the term that produced this hit
        launchSearchSession(ui, mention.term.text, false, return_info)
    else
        -- EPUB: regex-OR of every term so prev/next walks aliases too
        local pattern = buildSearchPattern(terms)
        if pattern then
            launchSearchSession(ui, pattern, true, return_info)
        else
            launchSearchSession(ui, terms[1].text, false, return_info)
        end
    end
end

--- Show where a single entity appears across the book (Chapter Appearances,
--- slice 4 shape): the full TOC hierarchy with a count at EVERY level,
--- computed from ONE gatherMentionHits pass — the same hit list the mention
--- pages render, so counts and lists always agree. No text extraction on
--- this surface anymore. Spoiler gating is display-only (see
--- _buildDistributionView).
--- Entry point: "Chapter Appearances" button in item detail view
--- @param item table The X-Ray item
--- @param category_key string Category key
--- @param item_title string Display name for the item
function XrayBrowser:showItemDistribution(item, category_key, item_title, detail_context)
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
        self:_buildDistributionView(item, category_key, item_title, cached, false, detail_context)
        return
    end

    if not self.ui.document.findAllText then
        UIManager:show(InfoMessage:new{
            text = _("Text search is not supported for this document."),
            timeout = 3,
        })
        return
    end
    local terms = collectSearchTerms(item, item_title)
    if #terms == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("No searchable name for \"%1\"."), item_title),
            timeout = 3,
        })
        return
    end

    UIManager:show(Notification:new{
        text = _("Computing distribution…"),
    })

    local self_ref = self
    UIManager:scheduleIn(0.2, function()
        local ui = self_ref.ui
        local gate = self_ref:_spoilerGate()

        -- Structure: the full TOC tree, or flat page-range chunks without a
        -- usable TOC. Ghost entries (markers sharing a page with a real
        -- chapter, e.g. Quran Juz pointers — end_page < start_page) carry no
        -- content and would only render dead 0-rows here (the picker keeps
        -- them: there they are jump targets).
        local raw_nodes, max_depth = getHierarchicalChapters(ui, gate, self_ref.scope)
        if not raw_nodes or #raw_nodes == 0 then
            raw_nodes = getAllPageRangeChapters(ui, gate)
            max_depth = 0
        end
        local nodes = {}
        for _idx, n in ipairs(raw_nodes or {}) do
            if n.end_page >= n.start_page then table.insert(nodes, n) end
        end
        if #nodes == 0 then
            UIManager:show(InfoMessage:new{
                text = _("Could not determine chapter structure."),
                timeout = 3,
            })
            return
        end

        -- ONE native pass: every hit, whole book (display gating comes later)
        local hits = gatherMentionHits(ui, terms)

        -- Per-page prefix sums → a node's count is one subtraction, at any depth
        local total_pages = ui.document.info.number_of_pages or 0
        local page_counts = {}
        for _idx, h in ipairs(hits) do
            local p = h.display_page
            if p and p >= 1 and p <= total_pages then
                page_counts[p] = (page_counts[p] or 0) + 1
            end
        end
        local prefix = { [0] = 0 }
        for p = 1, total_pages do
            prefix[p] = prefix[p - 1] + (page_counts[p] or 0)
        end
        local function spanCount(a, b)
            if b > total_pages then b = total_pages end
            if a < 1 then a = 1 end
            if b < a then return 0 end
            return prefix[b] - prefix[a - 1]
        end
        for _idx, n in ipairs(nodes) do
            n.count = spanCount(n.start_page, n.end_page)
            -- Clipped count for spans the gate cuts through (nil elsewhere)
            n.gated_count = (gate and n.start_page <= gate)
                and spanCount(n.start_page, math.min(n.end_page, gate)) or nil
        end
        local total_full = total_pages > 0 and prefix[total_pages] or #hits

        if total_full == 0 then
            local msg = ui.document.info.has_pages
                and T(_("No mentions of \"%1\" found. PDF text extraction may not be available for this document."), item_title)
                or T(_("No mentions of \"%1\" found in book text."), item_title)
            UIManager:show(InfoMessage:new{
                text = msg,
                timeout = 5,
            })
            return
        end

        -- Parent flags for the expand/collapse arrows (reverse pass — a node
        -- followed by a deeper node is a parent; the picker's idiom)
        do
            local depth = 0
            for i = #nodes, 1, -1 do
                if (nodes[i].depth or 1) < depth then
                    nodes[i]._is_parent = true
                end
                depth = nodes[i].depth or 1
            end
        end

        -- TOC-style initial view (maintainer round 2026-08-13): top level
        -- collapsed, the reader's current chain auto-expanded and focused
        local expanded = {}
        local cur_i, cur_depth = nil, -1
        for i, n in ipairs(nodes) do
            if n.is_current and (n.depth or 1) >= cur_depth then
                cur_depth = n.depth or 1
                cur_i = i
            end
        end
        -- Section browser with the reader outside the section: land on the
        -- first in-scope node instead
        if not cur_i and self_ref.scope then
            for i, n in ipairs(nodes) do
                if not n.out_of_scope then
                    cur_i = i
                    break
                end
            end
        end
        if cur_i then
            local d = nodes[cur_i].depth or 1
            for i = cur_i, 1, -1 do
                local nd = nodes[i].depth or 1
                if nd < d then
                    expanded[i] = true
                    d = nd
                end
            end
        end

        local data = {
            nodes = nodes,
            hits = hits,
            max_depth = max_depth,
            gate = gate,
            total_full = total_full,
            total_gated = gate and spanCount(1, gate) or nil,
            revealed = {},
            expanded = expanded,
            spoiler_warned = false,
            _focus_idx = cur_i,
        }
        self_ref._dist_cache[cache_key] = data
        self_ref:_buildDistributionView(item, category_key, item_title, data, false, detail_context)
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

--- Count other X-Rays available for cross-search (excludes current browser's X-Ray).
--- @return number count Number of other X-Rays
function XrayBrowser:_countOtherXrays()
    local book_file = self.metadata.book_file
    if not book_file then return 0 end
    local ActionCache = require("koassistant_action_cache")
    local sections = ActionCache.getSectionXrays(book_file)
    local main = ActionCache.getXrayCache(book_file)
    local total = #sections + (main and main.result and 1 or 0)
    return total > 1 and (total - 1) or 0
end

--- Open another X-Ray's browser from cross-section search results.
--- @param group table A result group from searchAllXrays()
--- @param result table A search result item to navigate to
function XrayBrowser:_openOtherXrayAtItem(group, result)
    local data = XrayParser.parse(group.cache_entry.result)
    if not data then return end
    local ActionCache = require("koassistant_action_cache")

    -- Merge user aliases
    if self.metadata.book_file then
        local user_aliases = ActionCache.getUserAliases(self.metadata.book_file)
        if next(user_aliases) then
            XrayParser.mergeUserAliases(data, user_aliases)
        end
    end

    -- Build scope for section X-Rays
    local scope = nil
    if group.is_section then
        scope = {
            label = group.label,
            start_page = group.cache_entry.scope_start_page,
            end_page = group.cache_entry.scope_end_page,
            page_summary = group.scope_summary or group.cache_entry.scope_page_summary,
            cache_key = group.key,
        }
    end

    local ce = group.cache_entry
    local browser_metadata = {
        title = self.metadata.title,
        progress = ce.progress_decimal and (math.floor(ce.progress_decimal * 100 + 0.5) .. "%"),
        model = ce.model,
        timestamp = ce.timestamp,
        book_file = self.metadata.book_file,
        enable_emoji = self.metadata.enable_emoji,
        configuration = self.metadata.configuration,
        plugin = self.metadata.plugin,
        progress_decimal = ce.progress_decimal,
        full_document = ce.full_document,
        merged_from_books = ce.merged_from_books,
        merged_from = ce.merged_from,
        scope = scope,
        _cleanup_widgets = self._cleanup_widgets,  -- preserve across X-Ray swaps
    }

    -- XrayBrowser is a singleton — close current browser before opening the new one.
    -- User returns to the book when they close the new browser.
    if self.menu then
        UIManager:close(self.menu)
    end
    self:show(data, browser_metadata, self.ui)
    local item_name = XrayParser.getItemName(result.item, result.category_key)
    self:showItemDetail(result.item, result.category_key, item_name)
end

--- Show cross-section search results (searches all OTHER X-Rays, navigates forward).
--- @param query string The search query
function XrayBrowser:_showCrossXrayResults(query)
    local ActionCache = require("koassistant_action_cache")
    local book_file = self.metadata.book_file
    if not book_file then return end

    UIManager:show(Notification:new{
        text = _("Searching other X-Rays…"),
    })
    local self_ref = self
    UIManager:scheduleIn(0.1, function()
        local doc = self_ref.ui and self_ref.ui.document
        local grouped = ActionCache.searchAllXrays(book_file, query, doc)

        -- Exclude current X-Ray from results
        local my_key = (self_ref.scope and self_ref.scope.cache_key) or "_xray_cache"
        local filtered = {}
        for _idx, group in ipairs(grouped) do
            if group.key ~= my_key then
                filtered[#filtered + 1] = group
            end
        end

        if #filtered == 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("No results for \"%1\" in other X-Rays."), query),
                timeout = 3,
            })
            return
        end

        -- Build grouped results view
        local items = {}
        local total_results = 0
        for _idx, group in ipairs(filtered) do
            total_results = total_results + #group.results

            -- Section header
            local header_label
            if not group.is_section then
                header_label = _("Main X-Ray")
            else
                header_label = group.label or ""
                if group.scope_summary and group.scope_summary ~= "" then
                    header_label = header_label .. " (" .. group.scope_summary .. ")"
                end
            end
            if group.in_range then
                header_label = "▸ " .. header_label
            end
            table.insert(items, {
                text = header_label,
                bold = true,
                separator = true,
                callback = function() end,
            })

            -- Result items
            for _idx2, result in ipairs(group.results) do
                local item_name = XrayParser.getItemName(result.item, result.category_key)
                local match_label = result.category_label
                if result.match_field == "alias" then
                    match_label = match_label .. " (" .. _("alias") .. ")"
                elseif result.match_field == "description" then
                    match_label = match_label .. " (" .. _("desc.") .. ")"
                end
                local captured_group = group
                local captured_result = result
                table.insert(items, {
                    text = "  " .. item_name,
                    mandatory = match_label,
                    mandatory_dim = true,
                    callback = function()
                        self_ref:_openOtherXrayAtItem(captured_group, captured_result)
                    end,
                })
            end
        end

        local title = T(_("Other X-Rays: \"%1\" (%2 across %3)"),
            query, total_results, #filtered)
        self_ref:navigateForward(title, items)
    end)
end

--- Show search results (navigates forward)
--- @param query string The search query
--- @param skip_cross_search boolean|nil Skip "Search other X-Rays" button (already searched)
function XrayBrowser:showSearchResults(query, skip_cross_search)
    local results = XrayParser.searchAll(self.xray_data, query)

    local items = {}
    local self_ref = self
    local other_count = self:_countOtherXrays()

    -- "Add as alias…" (ref #63): the no-hits dialog covers zero-hit
    -- lookups, but a handle worth adding usually DOES substring-hit other
    -- entries (a bare given name against the full-name entry) and lands on
    -- this list instead — the shared picker rides as the FIRST row (top
    -- placement per device round; above the identity header, since it acts
    -- on the query, not on any result group).
    local q_trim = query and query:match("^%s*(.-)%s*$") or ""
    if self.metadata and self.metadata.book_file and #q_trim > 2 and #q_trim <= 120 then
        local captured_query = query
        table.insert(items, {
            text = T(_("Add \"%1\" as an alias…"), query),
            bold = true,
            separator = true,
            callback = function()
                local Dialogs = require("koassistant_dialogs")
                Dialogs.showAliasTargetPicker{
                    data = self_ref.xray_data,
                    query = captured_query,
                    document_path = self_ref.metadata.book_file,
                    on_committed = function(target_item, target_cat_key, target_name)
                        self_ref:showItemDetail(target_item, target_cat_key, target_name)
                    end,
                }
            end,
        })
    end

    -- Show X-Ray identity header when launched from external lookup
    -- (user needs to know which X-Ray these results are from) — but only
    -- when OTHER X-Rays exist for the book; the book's sole X-Ray needs no
    -- identity line (device round 2026-08-14)
    if skip_cross_search and other_count > 0 then
        local header
        if self.scope then
            header = self.scope.label or ""
            if self.scope.page_summary and self.scope.page_summary ~= "" then
                header = header .. " (" .. self.scope.page_summary .. ")"
            end
        else
            header = _("Main X-Ray")
        end
        table.insert(items, {
            text = header,
            bold = true,
            separator = true,
            callback = function() end,
        })
    end

    if #results == 0 then
        -- Dimmed "no results" message
        table.insert(items, {
            text = _("No results in this X-Ray"),
            dim = true,
            callback = function() end,
        })
    else
        -- Build nav entries for prev/next navigation in detail view
        local nav_entries = {}
        for _idx, result in ipairs(results) do
            table.insert(nav_entries, {
                item = result.item,
                category_key = result.category_key,
                name = XrayParser.getItemName(result.item, result.category_key),
            })
        end

        for _idx, result in ipairs(results) do
            local nav_entry = nav_entries[_idx]
            local match_label = result.category_label
            if result.match_field == "alias" then
                match_label = match_label .. " (" .. _("alias") .. ")"
            elseif result.match_field == "description" then
                match_label = match_label .. " (" .. _("desc.") .. ")"
            end

            local captured_idx = _idx
            table.insert(items, {
                text = nav_entry.name,
                mandatory = match_label,
                mandatory_dim = true,
                callback = function()
                    self_ref:showItemDetail(nav_entry.item, nav_entry.category_key, nav_entry.name, nil, {
                        entries = nav_entries, index = captured_idx,
                    })
                end,
            })
        end
    end

    -- "Search other X-Rays" button when others exist
    -- Skip when caller already performed cross-section search (e.g., "Look up in X-Ray")
    if not skip_cross_search and other_count > 0 then
        local captured_query = query
        table.insert(items, {
            text = T(_("Search other X-Rays (%1)"), other_count),
            bold = true,
            separator = true,
            callback = function()
                self_ref:_showCrossXrayResults(captured_query)
            end,
        })
    end

    local title = T(_("Results for \"%1\" (%2)"), query, #results)
    self:navigateForward(title, items)
end

--- Show full rendered markdown view in ChatGPTViewer (overlays on menu)
function XrayBrowser:showFullView()
    local ChatGPTViewer = require("koassistant_chatgptviewer")

    -- Section X-Rays: use scope label instead of book title in markdown header
    local render_title = self.metadata.title or ""
    local render_progress = self.metadata.progress or ""
    if self.scope then
        render_title = self.scope.label or render_title
        if self.scope.page_summary and self.scope.page_summary ~= "" then
            render_title = render_title .. " (" .. self.scope.page_summary .. ")"
        end
        render_progress = ""  -- no progress percentage for section X-Rays
    end
    local markdown = XrayParser.renderToMarkdown(
        self.xray_data,
        render_title,
        render_progress
    )

    -- Build title bar: section X-Rays use scope, full X-Rays use book title
    local title
    if self.scope then
        title = T(_("X-Ray § %1"), self.scope.label)
        if self.metadata.title then
            title = title .. " - " .. self.metadata.title
        end
    else
        title = "X-Ray"
        if self.metadata.progress then
            title = title .. " (" .. self.metadata.progress .. ")"
        end
        if self.metadata.title then
            title = title .. " - " .. self.metadata.title
        end
    end

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

    -- Combined inline usage indicator (matching chat viewer style AND its
    -- show_*_indicator settings, which this view previously ignored)
    local display_text = markdown
    local ind_features = self.metadata.configuration and self.metadata.configuration.features
    local usage = Constants.buildUsageIndicator({
        reasoning = ((not ind_features or ind_features.show_reasoning_indicator ~= false)
            and self.metadata.used_reasoning) or nil,
        web_search = ((not ind_features or ind_features.show_web_search_indicator ~= false)
            and self.metadata.web_search_used) or nil,
    })
    if usage then
        display_text = usage .. "\n\n" .. markdown
    end

    -- Overlay on top of the menu — closing the viewer returns to the browser
    UIManager:show(ChatGPTViewer:new{
        title = title,
        text = display_text,
        _cache_content = markdown,
        simple_view = true,
        cache_metadata = self.metadata.cache_metadata,
        cache_type_name = "X-Ray",
        on_delete = on_delete_fullview,
        configuration = self.metadata.configuration,
        _info_text = self.metadata.info_popup_text,
        _artifact_file = self.metadata.book_file,
        _artifact_key = "_xray_cache",
        _artifact_book_title = self.metadata.title,
        _artifact_book_author = self.metadata.book_author,
        _book_open = (self.ui and self.ui.document ~= nil),
        _plugin = self.metadata.plugin,
        group_open = (self.metadata.plugin and self.metadata.plugin._inBookGroup
            and self.metadata.plugin:_inBookGroup(self.metadata.book_file))
            and function()
                self.metadata.plugin:_showGroupMembersPopup(self.metadata.book_file, "artifacts")
            end or nil,
        on_launch_chat = self.metadata.plugin and self.metadata.plugin._buildLaunchChatCallback
            and self.metadata.plugin:_buildLaunchChatCallback(self.metadata.book_file, self.metadata.title, self.metadata.book_author, markdown, _("X-Ray")) or nil,
    })
end

--- Show options menu (hamburger button)
function XrayBrowser:showOptions()
    local self_ref = self
    local buttons = {}

    local function closeOptions()
        if self_ref.options_dialog then
            UIManager:close(self_ref.options_dialog)
            self_ref.options_dialog = nil
        end
    end

    -- A2: the update / instant-install / switch rows come from the SHARED
    -- builder (koassistant_xray_rows.lua — one set of gates, labels and
    -- confirms with the X-Ray action popup; this hamburger previously lacked
    -- the free instant-install row and offered switch-back under the FULL
    -- posture). Live main views only, like every version surface here.
    local vr
    local vr_browser_closed = false
    if not self.scope and not self.metadata.checkpoint
        and self.metadata.plugin and self.metadata.book_file then
        local VrCache = require("koassistant_action_cache")
        local live = VrCache.getXrayCache(self.metadata.book_file)
        if live and live.result then
            local cur
            if self.ui and self.ui.document
                and self.ui.document.file == self.metadata.book_file then
                local ContextExtractor = require("koassistant_context_extractor")
                cur = ContextExtractor:new(self.ui):getReadingProgress()
            end
            vr = require("koassistant_xray_rows").versionRows({
                plugin = self.metadata.plugin,
                file = self.metadata.book_file,
                entry = live,
                current_progress = cur,
                on_update = self.on_update,
                align = "left",
                list_opts = { file = self.metadata.book_file,
                    book_title = self.metadata.title,
                    book_author = self.metadata.book_author,
                    -- Round 12: switches launched from an OPEN X-Ray land in
                    -- the switched-to one; popup-launched switches don't
                    -- (the switch helpers gate their reopen on this)
                    reopen_live = true },
                -- DEFERRED close for version browsing (device round 2): the
                -- list retires this browser only when a version is actually
                -- Viewed, Restored or Switched — Delete/Back leave it standing
                checkpoint_list_opts = { file = self.metadata.book_file,
                    book_title = self.metadata.title,
                    book_author = self.metadata.book_author,
                    reopen_live = true,
                    close_browser = function()
                        if not vr_browser_closed and self_ref.menu then
                            vr_browser_closed = true
                            UIManager:close(self_ref.menu)
                        end
                    end },
                pre = closeOptions,
                retire = function()
                    -- The operation replaces the data this browser renders
                    if self_ref.menu then UIManager:close(self_ref.menu) end
                end,
            })
        end
    end
    if self.on_update then
        if vr then
            if vr.update then table.insert(buttons, vr.update) end
            if vr.instant then table.insert(buttons, vr.instant) end
            if vr.switch_complete then table.insert(buttons, vr.switch_complete) end
        end

        -- The authoring form (extend / rebuild-from-scratch / checkpoints /
        -- background delivery) — mirrors the popup's entry for this state.
        -- Spacing slice: extend-mode books get the SPLIT row ([Extend…]
        -- [Rebuild…], build-shapes decision) — before it, a mid-book
        -- incremental book had no whole-book from-scratch path at all
        -- (whole-book in extend mode is an update)
        if self.on_extend_rebuild then
            local a_mode, a_base
            local am_plugin = self.metadata.plugin
            if am_plugin and am_plugin._xrayAuthoringMode and self.metadata.book_file then
                a_mode, a_base = am_plugin:_xrayAuthoringMode(self.metadata.book_file)
            end
            if a_mode == "extend" and (a_base or 0) < 0.995 then
                table.insert(buttons, {
                    { text = _("Extend…"), align = "left",
                        callback = function()
                            closeOptions()
                            if self_ref.menu then UIManager:close(self_ref.menu) end
                            self_ref.on_extend_rebuild()
                        end },
                    { text = _("Rebuild…"), align = "left",
                        callback = function()
                            closeOptions()
                            if self_ref.menu then UIManager:close(self_ref.menu) end
                            self_ref.on_extend_rebuild(true)
                        end },
                })
            else
                local er_label
                if a_mode == "rebuild" or a_mode == "extend" then
                    er_label = _("Rebuild X-Ray…")
                else
                    er_label = _("Create X-Ray…")
                end
                table.insert(buttons, {{
                    text = er_label, align = "left",
                    callback = function()
                        closeOptions()
                        if self_ref.menu then UIManager:close(self_ref.menu) end
                        self_ref.on_extend_rebuild()
                    end,
                }})
            end
        end
    end

    -- Free exit from ahead-mode (round 8 popup parity; A2: the shared builder
    -- also brings the 50(f) posture gate this row previously lacked here)
    if vr and vr.switch_back then
        table.insert(buttons, vr.switch_back)
    end
    -- One-tap built-ahead install (spacing slice; shared builder gates it)
    if vr and vr.install_ahead then
        table.insert(buttons, vr.install_ahead)
    end

    -- Delete option
    if self.on_delete then
        local delete_text = self.scope and _("Delete Section X-Ray") or _("Delete X-Ray")
        -- Round 13: deleting the main X-Ray clears the whole lineage — ring
        -- AND prepared versions (resurrection guard) — so the confirm says so.
        -- Round 28: archived versions are no longer collateral — the reader
        -- picks. A2: the choice content is SHARED with the cache viewer's
        -- delete (koassistant_xray_rows.deleteChoice), read at tap time.
        local function runDelete(keep_versions)
            self_ref.on_delete(keep_versions)
            if self_ref.menu then UIManager:close(self_ref.menu) end
        end
        table.insert(buttons, {{
            text = delete_text, align = "left",
            callback = function()
                closeOptions()
                local choice = (not self_ref.scope and self_ref.metadata
                    and self_ref.metadata.book_file)
                    and require("koassistant_xray_rows").deleteChoice(self_ref.metadata.book_file)
                    or nil
                if choice and choice.two_way then
                    local del_dialog
                    del_dialog = ButtonDialog:new{
                        title = choice.title,
                        buttons = {
                            {{ text = choice.keep_text,
                               callback = function()
                                   UIManager:close(del_dialog)
                                   runDelete(true)
                               end }},
                            {{ text = choice.drop_text,
                               callback = function()
                                   UIManager:close(del_dialog)
                                   runDelete(false)
                               end }},
                            {{ text = _("Cancel"),
                               callback = function() UIManager:close(del_dialog) end }},
                        },
                    }
                    UIManager:show(del_dialog)
                    return
                end
                local delete_confirm
                if self_ref.scope then
                    delete_confirm = T(_("Delete Section X-Ray \"%1\"? This cannot be undone."), self_ref.scope.label or "")
                elseif choice then
                    delete_confirm = choice.title
                else
                    delete_confirm = _("Delete this X-Ray? This cannot be undone.")
                end
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = delete_confirm,
                    ok_text = _("Delete"),
                    ok_callback = function() runDelete(false) end,
                })
            end,
        }})
    end

    -- Archived versions (#73): main X-Ray only — sections have no ring, and an
    -- archived view offering its own history would recurse. Ring + ladder
    -- rungs, from the shared builder (deferred close rides its
    -- checkpoint_list_opts above).
    if vr and vr.all_versions then
        table.insert(buttons, vr.all_versions)
    end

    -- Merge section X-Rays (§6 slice 3, #90): main X-Ray views only (a section
    -- view merging its own peers would confuse the landing surface); archived
    -- views stay read-only
    if not self.scope and not self.metadata.checkpoint
        and self.metadata.plugin and self.metadata.book_file then
        local ActionCache = require("koassistant_action_cache")
        local sec_count = ActionCache.getSectionCount(self.metadata.book_file,
            ActionCache.SECTION_PREFIXES.xray)
        if sec_count > 0 then
            table.insert(buttons, {{
                text = T(_("Merge section X-Rays (%1)…"), sec_count), align = "left",
                callback = function()
                    closeOptions()
                    -- Close the browser: a successful into-main merge replaces the
                    -- data this view renders. Deferred to list-open (device
                    -- round 2 T11): an empty flow must leave the browser up.
                    local browser_closed = false
                    require("koassistant_xray_merge").startFlow({
                        file = self_ref.metadata.book_file,
                        ui = self_ref.ui,
                        plugin = self_ref.metadata.plugin,
                        configuration = self_ref.metadata.configuration,
                        title = self_ref.metadata.title,
                        author = self_ref.metadata.book_author,
                        reopen_live = true,
                        close_browser = function()
                            if not browser_closed and self_ref.menu then
                                browser_closed = true
                                UIManager:close(self_ref.menu)
                            end
                        end,
                    })
                end,
            }})
        end
        -- Cross-book merge (item 43, #90 v1): fold another book's X-Ray into
        -- this one as background. Main views only, same rationale as above;
        -- the flow's early returns (no candidates / consent) leave the
        -- browser up (close deferred to the actual merge start).
        table.insert(buttons, {{
            text = _("Merge from another book…"), align = "left",
            callback = function()
                closeOptions()
                local xb_browser_closed = false
                require("koassistant_xray_merge").startCrossBookFlow({
                    file = self_ref.metadata.book_file,
                    ui = self_ref.ui,
                    plugin = self_ref.metadata.plugin,
                    configuration = self_ref.metadata.configuration,
                    title = self_ref.metadata.title,
                    author = self_ref.metadata.book_author,
                    -- The fold closes this browser; reopen the X-Ray on the
                    -- merged data when it lands (round 27)
                    reopen_live = true,
                    close_browser = function()
                        if not xb_browser_closed and self_ref.menu then
                            xb_browser_closed = true
                            UIManager:close(self_ref.menu)
                        end
                    end,
                })
            end,
        }})
        -- Book group row (item 46): one popup of the group's members — tap a
        -- volume to switch to ITS live X-Ray (grayed when it has none).
        -- Checked LAZILY here (not threaded through browser metadata): every
        -- show path gets it — incl. the fresh-generation display — and a
        -- group created while the browser is open appears on the next tap.
        if self.metadata.plugin and self.metadata.plugin._inBookGroup
            and self.metadata.plugin:_inBookGroup(self.metadata.book_file) then
            local plugin_ref = self.metadata.plugin
            local group_file = self.metadata.book_file
            table.insert(buttons, {{
                text = "→ " .. _("Group"),
                align = "left",
                callback = function()
                    closeOptions()
                    plugin_ref:_showGroupMembersPopup(group_file, "xray", {
                        -- Round 25: carry where the reader is, so the other
                        -- volume opens at the same entity/category when it has
                        -- one (see _applyPendingLocation's fallback ladder)
                        location = self_ref.location,
                        before_open = function()
                            if self_ref.menu then UIManager:close(self_ref.menu) end
                        end,
                    })
                end,
            }})
        end
    end

    -- Round 24 (maintainer: version viewers dead-ended at Info): an archived-
    -- version view gets its version's own actions — restore/delete via the
    -- same options dialogs the All-versions list uses, plus the list itself.
    if not self.scope and self.metadata.checkpoint
        and self.metadata.plugin and self.metadata.book_file
        and self.metadata.checkpoint_data then
        local v_opts = {
            file = self.metadata.book_file,
            book_title = self.metadata.title,
            book_author = self.metadata.book_author,
            -- Round 27 device follow-up: installing from an OPEN version view
            -- ("View" then the hamburger's Install) left the reader on nothing
            -- — this view is retired by the install, so land on the live X-Ray
            -- exactly as the direct install from the list does
            reopen_live = true,
        }
        -- Rung cards install (slice 2, 35 E3(ii)) or delete; intro rungs have
        -- no install (premise-only) so their row keeps the narrower promise
        local viewed_is_rung = self.metadata.plugin:_xrayVersionIsRung(
            self.metadata.checkpoint_data, self.metadata.book_file)
        table.insert(buttons, {{
            text = viewed_is_rung and (self.metadata.checkpoint_data.intro
                    and _("Delete this checkpoint…")
                    or _("Install or delete this checkpoint…"))
                or _("Install or delete this version…"), align = "left",
            callback = function()
                closeOptions()
                -- Restore/delete replace or remove what this view renders —
                -- retire the browser first
                if self_ref.menu then UIManager:close(self_ref.menu) end
                self_ref.metadata.plugin:_showXrayVersionOptions(
                    self_ref.metadata.checkpoint_data, self_ref.metadata.book_file, v_opts)
            end,
        }})
        table.insert(buttons, {{
            text = _("Other versions…"), align = "left",
            callback = function()
                closeOptions()
                local browser_closed = false
                self_ref.metadata.plugin:_showXrayCheckpointList({
                    file = self_ref.metadata.book_file,
                    book_title = self_ref.metadata.title,
                    book_author = self_ref.metadata.book_author,
                    reopen_live = true,
                    close_browser = function()
                        if not browser_closed and self_ref.menu then
                            browser_closed = true
                            UIManager:close(self_ref.menu)
                        end
                    end,
                })
            end,
        }})
    end

    -- Find duplicate entities (§6 slice 4, #90): main X-Ray views only, same
    -- rationale as the merge row; the flow operates on disk truth
    if not self.scope and not self.metadata.checkpoint
        and self.metadata.plugin and self.metadata.book_file then
        table.insert(buttons, {{
            text = _("Find duplicate entities…"), align = "left",
            callback = function()
                closeOptions()
                -- Close the browser only when the pair list actually opens (a
                -- merge rewrites the data this view renders) — an empty scan
                -- must leave the browser up (device round 2 T11)
                local browser_closed = false
                require("koassistant_xray_dedup").startFlow({
                    file = self_ref.metadata.book_file,
                    ui = self_ref.ui,
                    plugin = self_ref.metadata.plugin,
                    configuration = self_ref.metadata.configuration,
                    title = self_ref.metadata.title,
                    author = self_ref.metadata.book_author,
                    close_browser = function()
                        if not browser_closed and self_ref.menu then
                            browser_closed = true
                            UIManager:close(self_ref.menu)
                        end
                    end,
                })
            end,
        }})
    end

    -- Info
    local info_parts = {}
    if self.scope then
        table.insert(info_parts, _("Section:") .. " " .. (self.scope.label or ""))
        table.insert(info_parts, _("Pages:") .. " " .. (self.scope.page_summary or ""))
    end
    if self.metadata.model then
        table.insert(info_parts, _("Model:") .. " " .. self.metadata.model)
    end
    if not self.scope and self.metadata.progress then
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
    local type_label = XrayParser.isAcademic(self.xray_data) and _("Academic")
        or XrayParser.isFiction(self.xray_data) and _("Fiction")
        or _("Non-Fiction")
    table.insert(info_parts, _("Type:") .. " " .. type_label)
    if self.metadata.source_label then
        table.insert(info_parts, _("Source:") .. " " .. self.metadata.source_label)
    end
    if self.metadata.used_reasoning then
        table.insert(info_parts, _("Reasoning:") .. " " .. _("Yes"))
    end
    if self.metadata.web_search_used then
        table.insert(info_parts, _("Web search:") .. " " .. _("Yes"))
    end
    -- Merge provenance (T12): the field records the LAST merge's input count
    if tonumber(self.metadata.merged_from_sections) then
        table.insert(info_parts, _("Merged from:") .. " "
            .. T(_("%1 section X-Rays"), self.metadata.merged_from_sections))
    end
    -- Cross-book provenance (item 43 → round 31 ledger): one line per source,
    -- and every source that recorded a version is checked against its book's
    -- CURRENT X-Ray — one cache read per file-keyed source, only at Info-tap
    -- time — so "folded" and "folded but changed since" read differently here
    -- too, not just in the fold confirms. Title-only records (legacy or
    -- transitively carried) make no claim.
    local prov_ledger = require("koassistant_xray_merge").ledgerOf(self.metadata)
    if #prov_ledger > 0 then
        local ProvActionCache = require("koassistant_action_cache")
        table.insert(info_parts, _("Includes background from:"))
        for _idx, rec in ipairs(prov_ledger) do
            local line = "  • " .. rec.title
            if rec.file and rec.source_ts then
                local src = ProvActionCache.getXrayCache(rec.file)
                local src_ts = src and tonumber(src.timestamp)
                if src_ts then
                    line = line .. " — " .. (src_ts > tonumber(rec.source_ts)
                        and _("changed since the fold") or _("up to date"))
                end
            end
            table.insert(info_parts, line)
        end
    end
    -- Ladder provenance (device round 2): derived from disk truth at tap time —
    -- no cache fields involved, so it stays honest across ladder deletion and
    -- later API updates. Live main only (not section/checkpoint views).
    if not self.scope and not self.metadata.checkpoint and self.metadata.book_file then
        local InfoActionCache = require("koassistant_action_cache")
        local info_ladder = InfoActionCache.getXrayLadder(self.metadata.book_file)
        if #info_ladder > 0 then
            local highest = InfoActionCache.highestXrayLadderProgress(info_ladder) or 0
            table.insert(info_parts, T(_("Checkpoints: %1 (up to %2%)"),
                #info_ladder, math.floor(highest * 100 + 0.5)))
            for _idx, rung in ipairs(info_ladder) do
                if rung.timestamp == self.metadata.timestamp
                    and math.abs((tonumber(rung.progress_decimal) or -1)
                        - (tonumber(self.metadata.progress_decimal) or -2)) < 1e-6 then
                    table.insert(info_parts, rung.chapter_label
                        and T(_("Installed from checkpoint (end of %1)"), rung.chapter_label)
                        or _("Installed from checkpoint"))
                    break
                end
            end
        end
    end

    if #info_parts > 0 then
        table.insert(buttons, {{
            text = _("Info"), align = "left",
            callback = function()
                closeOptions()
                UIManager:show(InfoMessage:new{
                    text = table.concat(info_parts, "\n"),
                })
            end,
        }})
    end

    -- Open Book (when viewing from file browser without the book open)
    if (not self.ui or not self.ui.document) and self.metadata.book_file then
        table.insert(buttons, {{
            text = _("Open Book"), align = "left",
            callback = function()
                closeOptions()
                self_ref:_openBookFile()
            end,
        }})
    end

    if self.options_dialog then
        UIManager:close(self.options_dialog)
    end
    self.options_dialog = ButtonDialog:new{
        buttons = buttons,
        shrink_unneeded_width = true,
        anchor = function()
            return self_ref.menu.title_bar.left_button.image.dimen, true
        end,
    }
    UIManager:show(self.options_dialog)
end

-- Get available non-xray artifacts for this book
function XrayBrowser:_getAvailableArtifacts()
    local book_file = self.metadata.book_file
    if not book_file then return {} end
    local ActionCache = require("koassistant_action_cache")
    -- Exclude current cache key: main _xray_cache or section key
    local exclude_key = "_xray_cache"
    if self.scope and self.scope.cache_key then
        exclude_key = self.scope.cache_key
    end
    local doc = self.ui and self.ui.document
    return ActionCache.getAvailableArtifactsWithPinned(book_file, exclude_key, doc)
end

-- Check if an artifact key would open another X-Ray browser
function XrayBrowser:_isXrayArtifact(art)
    if art.is_section_xray_group then return true end
    local ActionCache = require("koassistant_action_cache")
    return art.key == "_xray_cache"
        or (type(art.key) == "string"
            and art.key:sub(1, #ActionCache.SECTION_XRAY_PREFIX) == ActionCache.SECTION_XRAY_PREFIX)
end

-- Open a specific artifact viewer
function XrayBrowser:_openArtifact(art)
    local plugin = self.metadata.plugin
    if not plugin then return end
    local book_file = self.metadata.book_file
    local book_title = self.metadata.title or ""
    -- Close current browser before opening another X-Ray browser (prevents stacking)
    -- For section groups, defer closing until user picks a specific section
    if not art.is_section_xray_group and self:_isXrayArtifact(art) and self.menu then
        UIManager:close(self.menu)
    end
    if art.is_section_xray_group then
        self:_showSectionXrayGroupPopup(art.data, art._excluded_section_key)
    elseif art.is_section_group then
        local ArtifactBrowser = require("koassistant_artifact_browser")
        ArtifactBrowser:_showSectionGroupPopup(
            art.data, book_file, book_title, plugin,
            art.section_type, art._excluded_section_key)
    elseif art.is_wiki_group then
        self:_showWikiGroupPopup(art.data)
    elseif art.is_pinned_group then
        self:_showPinnedGroupPopup(art.data)
    elseif art.is_image_group then
        -- Gallery opens on top; the X-Ray browser stays open beneath
        local ImageBrowser = require("koassistant_image_browser")
        ImageBrowser.show({ book_file = book_file, book_title = book_title })
    elseif art.is_xray_versions_group then
        -- Close the browser first: viewing an archived version reuses the
        -- module-level XrayBrowser state
        if self.menu then UIManager:close(self.menu) end
        plugin:_showXrayCheckpointList({ file = book_file, book_title = book_title })
    elseif art.is_per_action then
        plugin:viewCachedAction(
            { text = art.name }, art.key, art.data,
            { file = book_file, book_title = book_title })
    else
        plugin:showCacheViewer({
            name = art.name, key = art.key, data = art.data,
            book_title = book_title, file = book_file })
    end
end

-- Show popup listing individual section X-Rays from a group entry
function XrayBrowser:_showSectionXrayGroupPopup(sections, excluded_key)
    local ActionCache = require("koassistant_action_cache")
    local plugin = self.metadata.plugin
    if not plugin then return end
    local book_file = self.metadata.book_file
    local book_title = self.metadata.title or ""
    local self_ref = self

    local buttons = {}
    for _idx, sec in ipairs(sections) do
        if sec.key ~= excluded_key then
            local captured = sec
            local label = captured.label or captured.key
            local sec_doc = self_ref.ui and self_ref.ui.document
            local page_info = captured.data and ActionCache.reconvertPageSummary(captured.data, sec_doc) or ""
            local display = page_info ~= "" and (label .. " (" .. page_info .. ")") or label
            table.insert(buttons, {{
                text = display,
                callback = function()
                    if self_ref._section_group_dialog then
                        UIManager:close(self_ref._section_group_dialog)
                    end
                    if self_ref._artifacts_dialog then
                        UIManager:close(self_ref._artifacts_dialog)
                    end
                    -- Close current browser before opening another (prevents stacking)
                    if self_ref.menu then
                        UIManager:close(self_ref.menu)
                    end
                    plugin:showCacheViewer({
                        name = label, key = captured.key, data = captured.data,
                        book_title = book_title, file = book_file })
                end,
            }})
        end
    end

    if #buttons == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No other Section X-Rays available."),
            timeout = 3,
        })
        return
    end

    self._section_group_dialog = ButtonDialog:new{
        title = _("View Section X-Rays"),
        buttons = buttons,
    }
    UIManager:show(self._section_group_dialog)
end

-- Show popup listing individual wiki entries from a group entry
function XrayBrowser:_showWikiGroupPopup(wiki_entries)
    local ChatGPTViewer = require("koassistant_chatgptviewer")
    local ActionCache = require("koassistant_action_cache")
    local book_file = self.metadata.book_file
    local self_ref = self

    local buttons = {}
    for _idx, wiki in ipairs(wiki_entries) do
        local captured = wiki
        table.insert(buttons, {{
            text = captured.label,
            callback = function()
                if self_ref._wiki_group_dialog then
                    UIManager:close(self_ref._wiki_group_dialog)
                end
                if self_ref._artifacts_dialog then
                    UIManager:close(self_ref._artifacts_dialog)
                end
                local viewer = ChatGPTViewer:new{
                    title = T(_("AI Wiki: %1"), captured.label),
                    text = captured.data.result,
                    simple_view = true,
                    cache_type_name = _("AI Wiki"),
                    on_delete = function()
                        ActionCache.clear(book_file, captured.key)
                        UIManager:show(Notification:new{
                            text = _("AI Wiki deleted"),
                            timeout = 2,
                        })
                    end,
                    _book_open = self_ref.ui and self_ref.ui.document ~= nil,
                    _plugin = self_ref.metadata.plugin,
                    _artifact_file = book_file,
                    _artifact_key = captured.key,
                    _artifact_book_title = self_ref.metadata.title,
                    _artifact_book_author = self_ref.metadata.author,
                    on_launch_chat = self_ref.metadata.plugin and self_ref.metadata.plugin._buildLaunchChatCallback
                        and self_ref.metadata.plugin:_buildLaunchChatCallback(book_file, self_ref.metadata.title, self_ref.metadata.author, captured.data.result, _("AI Wiki")) or nil,
                }
                UIManager:show(viewer)
            end,
        }})
    end

    if #buttons == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No AI Wiki entries available."),
            timeout = 3,
        })
        return
    end

    self._wiki_group_dialog = ButtonDialog:new{
        title = _("AI Wiki Entries"),
        buttons = buttons,
    }
    UIManager:show(self._wiki_group_dialog)
end

-- Show popup listing pinned artifacts from a group entry
function XrayBrowser:_showPinnedGroupPopup(pinned_entries)
    local ChatGPTViewer = require("koassistant_chatgptviewer")
    local PinnedManager = require("koassistant_pinned_manager")
    local book_file = self.metadata.book_file
    local self_ref = self

    local buttons = {}
    for _idx, pin in ipairs(pinned_entries) do
        local captured = pin
        local label = captured.name or captured.action_text or _("Pinned")
        table.insert(buttons, {{
            text = label,
            callback = function()
                if self_ref._pinned_group_dialog then
                    UIManager:close(self_ref._pinned_group_dialog)
                end
                if self_ref._artifacts_dialog then
                    UIManager:close(self_ref._artifacts_dialog)
                end
                local display_name = captured.name or captured.action_text or _("Pinned")
                local info_parts = {}
                if captured.action_text and captured.action_text ~= "" then
                    table.insert(info_parts, _("Action") .. ": " .. captured.action_text)
                end
                if captured.model and captured.model ~= "" then
                    table.insert(info_parts, _("Model") .. ": " .. captured.model)
                end
                if captured.timestamp and captured.timestamp > 0 then
                    table.insert(info_parts, _("Pinned") .. ": " .. os.date("%B %d, %Y", captured.timestamp))
                end
                if captured.user_prompt and captured.user_prompt ~= "" then
                    local preview = captured.user_prompt:sub(1, 200)
                    if #captured.user_prompt > 200 then preview = preview .. "..." end
                    table.insert(info_parts, _("Prompt") .. ": " .. preview)
                end
                local viewer = ChatGPTViewer:new{
                    title = display_name .. " (" .. _("Pinned") .. ")",
                    text = captured.result or "",
                    simple_view = true,
                    cache_type_name = _("pinned artifact"),
                    cache_metadata = {
                        cache_type = "pinned",
                        book_title = captured.book_title,
                        book_author = captured.book_author,
                        model = captured.model,
                        timestamp = captured.timestamp,
                    },
                    _info_text = #info_parts > 0 and table.concat(info_parts, "\n") or nil,
                    on_delete = function()
                        PinnedManager.removePin(book_file, captured.id)
                        UIManager:show(Notification:new{
                            text = _("Pinned artifact removed"),
                            timeout = 2,
                        })
                    end,
                    _book_open = self_ref.ui and self_ref.ui.document ~= nil,
                    _plugin = self_ref.metadata.plugin,
                    _artifact_file = book_file,
                    _artifact_key = "pinned:" .. (captured.id or ""),
                    _artifact_book_title = self_ref.metadata.title,
                    _artifact_book_author = self_ref.metadata.author,
                    on_launch_chat = self_ref.metadata.plugin and self_ref.metadata.plugin._buildLaunchChatCallback
                        and self_ref.metadata.plugin:_buildLaunchChatCallback(book_file, self_ref.metadata.title, self_ref.metadata.author, captured.result, captured.action_text or _("Pinned")) or nil,
                }
                UIManager:show(viewer)
            end,
        }})
    end

    if #buttons == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No pinned artifacts available."),
            timeout = 3,
        })
        return
    end

    self._pinned_group_dialog = ButtonDialog:new{
        title = _("Pinned Artifacts"),
        buttons = buttons,
    }
    UIManager:show(self._pinned_group_dialog)
end

-- Show popup listing other cached artifacts (for 2+ artifacts)
function XrayBrowser:_showOtherArtifacts(available)
    if not available or #available == 0 then return end

    local self_ref = self
    local buttons = {}
    for _idx, art in ipairs(available) do
        local captured = art
        local label = captured.name
        -- Shared meta (A4 parity): "Recap (6%, today)", percent always
        if not (captured.is_pinned_group or captured.is_section_group
                or captured.is_section_xray_group or captured.is_wiki_group) then
            local meta = Constants.formatArtifactMeta(captured.data)
            if meta then label = label .. " (" .. meta .. ")" end
        end
        table.insert(buttons, {{
            text = label,
            callback = function()
                if not (captured.is_section_group or captured.is_wiki_group or captured.is_pinned_group) then
                    if self_ref._artifacts_dialog then
                        UIManager:close(self_ref._artifacts_dialog)
                    end
                end
                self_ref:_openArtifact(captured)
            end,
        }})
    end

    self._artifacts_dialog = ButtonDialog:new{
        title = _("Other Artifacts"),
        buttons = buttons,
    }
    UIManager:show(self._artifacts_dialog)
end

--- Open the book file in Reader mode (closing the browser)
--- Saves pending reopen state so onReaderReady can auto-reopen the X-Ray browser
--- @param navigate_to table|nil Optional {category_key, item_name} to restore position
function XrayBrowser:_openBookFile(navigate_to)
    local book_file = self.metadata and self.metadata.book_file
    if not book_file then return end
    -- Save pending reopen state on the module table (survives plugin re-instantiation)
    XrayBrowser._pending_reopen = {
        book_file = book_file,
        navigate_to = navigate_to,
    }
    if self.menu then
        UIManager:close(self.menu)
    end
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(book_file)
end

--- Show popup explaining a feature requires the book to be open in Reader mode
--- @param navigate_to table|nil Optional {category_key, item_name} to restore position on reopen
function XrayBrowser:_showReaderRequired(navigate_to)
    local self_ref = self
    if self.metadata and self.metadata.book_file then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("This feature requires the book to be open in Reader mode.\n\nOpen the book now?"),
            ok_text = _("Open Book"),
            ok_callback = function()
                self_ref:_openBookFile(navigate_to)
            end,
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("This feature requires the book to be open in Reader mode."),
        })
    end
end

return XrayBrowser
