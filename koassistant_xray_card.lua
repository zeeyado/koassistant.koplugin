--[[--
Compact entity card (A10 point-4, ref #78 / #63): ONE landing surface for
exact entity hits — the ambient-mark tap and both selection intercepts all
open this instead of jumping straight into the full browser entry.

Two tiers (maintainer design 2026-08-14):
- The CARD is the identification tier: name, category (+ role when the
  artifact has one — "Protagonist / Supporting"), the description's first
  sentence. It may draw from the NEWEST BUILT checkpoint even when that is
  ahead of the reader — "know who characters are when they first appear" —
  which is the deliberate, bounded peek.
- Tapping the card is the position tier: it resolves against the INSTALLED
  artifact via the existing exact-match lookup path (browser detail, natural
  back stack). An entity that exists ONLY ahead reveals its full entry
  behind a confirm while spoiler protection is on; with protection off the
  live artifact is the newest anyway (promotion), so no split exists.

Two presentation styles (round 15, `features.xray_card_style`):
- "footnote" (default): KOReader's FootnoteWidget — the bottom panel readers
  know from footnote popups, rendered with the book's margins/font size.
  Tap the panel (or swipe west / Press) = full entry; tap outside = dismiss.
- "popup": the plugin's MinimalPopup — a small floating window anchored next
  to the tapped word when selection geometry is available (EPUB; centered
  fallback). Tap inside = full entry (its native expand idiom); outside =
  dismiss.

The module is UI + pure resolution only; routing and the landing preference
(`features.xray_card_landing`) live in main.lua's AskGPT:openXrayCard, which
passes { style, ui, sboxes, on_full } through `opts`.
]]

local UIManager = require("ui/uimanager")
local logger = require("koassistant_logger")
local T = require("ffi/util").template
local _ = require("koassistant_gettext")

local XrayCard = {}

-- Terminator tokens that are abbreviations, not sentence ends (case-folded).
local ABBREV = {
    mr = true, mrs = true, ms = true, dr = true, prof = true, sr = true, jr = true,
    st = true, mt = true, ft = true, vs = true, etc = true, jan = true, feb = true,
    mar = true, apr = true, jun = true, jul = true, aug = true, sep = true, sept = true,
    oct = true, nov = true, dec = true, no = true, vol = true, op = true, ch = true,
    ed = true, gen = true, col = true, capt = true, lt = true, sgt = true, rev = true,
    hon = true, sen = true, rep = true, gov = true, pres = true, inc = true, co = true,
    ltd = true, univ = true, dept = true, approx = true, cf = true, e = true, i = true,
    ie = true, eg = true, al = true, ph = true,
}

--- Position of the first sentence terminator that really ends a sentence,
--- or nil. Skips abbreviations ("Mr.", "H.S.", "etc."): a period whose
--- preceding token is a single letter, an initial chain ("H.S", "U.S.A") or
--- a listed abbreviation, or whose next word starts lowercase, is not a
--- sentence end. "?"/"!" and the Arabic marks always end one.
function XrayCard.sentenceEnd(s)
    local pos = 1
    while true do
        local cut = s:find("[%.!%?]%s", pos)
        local acut = s:find("؟%s", pos) or s:find("۔%s", pos)
        if acut and (not cut or acut < cut) then return acut + 1 end
        -- CJK full-width stops carry no following space (2026-08-25, ref #90:
        -- a CJK description never found a sentence end and fell to the cap)
        local ccut
        for _idx, mark in ipairs({ "。", "！", "？" }) do  -- plain finds: a [] class would match bytes
            local c = s:find(mark, pos, true)
            if c and (not ccut or c < ccut) then ccut = c end
        end
        if ccut and (not cut or ccut < cut) then return ccut + 2 end
        if not cut then return nil end
        if s:sub(cut, cut) ~= "." then return cut end
        local before = s:sub(1, cut - 1):match("([%w%.]*)$") or ""
        local token = before:gsub("%.", ""):lower()
        local nxt = s:sub(cut + 1):match("^%s*(.)")
        local abbrev = before:find("%.") ~= nil       -- initial chain "H.S" / "U.S"
            or #token == 1                            -- single initial "J."
            or ABBREV[token] ~= nil
            or (nxt ~= nil and nxt:find("%l") ~= nil) -- next word lowercase
        if not abbrev then return cut end
        pos = cut + 1
    end
end

--- First sentence of a description, capped — the identification line.
--- Pure (unit-testable). Sentence end = period/question/exclamation (ASCII +
--- Arabic ؟ / ۔) followed by whitespace; falls back to a word-boundary cap.
--- @param desc string|nil
--- @return string ("" when nothing usable)
function XrayCard.firstSentence(desc)
    if type(desc) ~= "string" then return "" end
    local s = desc:match("^%s*(.-)%s*$") or ""
    if s == "" then return "" end
    local cut = XrayCard.sentenceEnd(s)
    local first = cut and s:sub(1, cut) or s
    if #first > 220 then
        first = first:sub(1, 220)
        -- Never split a multibyte character (a CJK sentence has no spaces
        -- for the word-boundary trim to find)
        while #first > 0 and first:byte(-1) >= 0x80 and first:byte(-1) < 0xC0 do
            first = first:sub(1, -2)
        end
        if #first > 0 and first:byte(-1) >= 0xC0 then first = first:sub(1, -2) end
        if first:find("%s") then first = first:gsub("%s+%S*$", "") end
        first = first .. "…"
    end
    return first
end

--- The item's description-ish text, whatever field the category uses.
local function itemText(item)
    if type(item) ~= "table" then return "" end
    for _idx, f in ipairs({ "description", "definition", "significance", "summary" }) do
        if type(item[f]) == "string" and item[f] ~= "" then return item[f] end
    end
    return ""
end

--- "Category (Role)" — the classification half of the identity line.
--- Role rides only when short (fiction-style "Protagonist"; the non-fiction
--- schema allows sentence-length roles, which belong to the description).
local function kindLabel(hit, no_role)
    local label = type(hit.category_label) == "string" and hit.category_label or ""
    local role = type(hit.item) == "table" and type(hit.item.role) == "string"
        and hit.item.role or ""
    role = role:gsub("^%s+", ""):gsub("[%s%.]+$", "")
    if role ~= "" and #role <= 48 and not no_role then
        label = label ~= "" and (label .. " (" .. role .. ")") or role
    end
    return label
end

--- The ahead-entity warning line, or nil. ONE line on every surface (both
--- card styles + the full-detail viewer): leading ⚠ + EARLY placement
--- (2026-08-16 filing 2f, maintainer-marked important) + spoiler-first
--- wording (round 7, maintainer: "capture the spoiler alert better" — the
--- old "(from the checkpoint built to N%)" read as neutral provenance).
--- U+26A0 renders in both card paths (MuPDF HTML and TextBoxWidget — the
--- truncation notices proved it); code-prepended so the msgid stays clean.
local function aheadLine(hit)
    if hit.source == "ahead" and hit.ahead_progress then
        return "\u{26A0} " .. T(_("From the next checkpoint (to %1%), may contain spoilers"),
            math.floor(hit.ahead_progress * 100 + 0.5))
    end
end

--- Carried/predecessor provenance line (S1 D3 + S2, ref #90), no warning
--- glyph — an earlier volume in the reading order is already-read content by
--- the group's own definition. S3 parity (maintainer 2026-09-02): the
--- category slot reads the same on both cards, so THIS line carries the
--- difference in plain words — an entry on this book's carried list (or a
--- carried entry seen in the earlier book) says "Carried from <title>", an
--- entry read straight out of the earlier book's X-Ray says "From <title>'s
--- X-Ray". Q6 (2026-09-01): when the next checkpoint ALSO knows the name,
--- say so in one clause — the reader can then choose to update/install for
--- this book's own take; the carried entry stays the one shown.
local function carriedLine(hit)
    if (hit.source == "carried" or hit.source == "predecessor")
        and type(hit.source_title) == "string" and hit.source_title ~= "" then
        local line
        if hit.source == "carried" or hit.pred_stub then
            line = T(_("Carried from %1"), hit.source_title)
        elseif hit.direction == "later" then
            -- S4: a later volume's entry, reachable only while this book is
            -- not under spoiler protection — name the direction
            line = T(_("From %1's X-Ray (later in the series)"), hit.source_title)
        else
            line = T(_("From %1's X-Ray"), hit.source_title)
        end
        if hit.also_ahead then
            line = line .. " \u{00B7} " .. T(_("Also in the next checkpoint (to %1%)"),
                math.floor(hit.also_ahead * 100 + 0.5))
        end
        return line
    end
end

--- True when the tapped handle differs from the entry's own name (the hit
--- came through an alias). Case- and whitespace-insensitive. Pure.
function XrayCard.isAliasHit(hit)
    local q = type(hit.query) == "string" and hit.query or ""
    local n = type(hit.name) == "string" and hit.name or ""
    if q == "" or n == "" then return false end
    local function fold(x) return x:lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "") end
    return fold(q) ~= fold(n)
end

--- B269 STAGED card content, one place for both styles.
--- Ahead (upcoming) hits show the TAPPED handle as the name line (the
--- entry's primary name may itself be the reveal — an alias folded onto the
--- identity) and reveal in stages inside the card: stage "name" = category
--- only (no role — roles are model-written and can spoil), the next-checkpoint
--- warning and a tap hint; stage "sentence" = role + first sentence; the
--- next tap is the full entry (router-owned, behind its confirm). Installed
--- hits start at the sentence stage (opts.card_length "full" = whole
--- description, opt-in). An ahead hit reached through an ALIAS (the tapped
--- handle is not the entry's own name — "A is actually B" folded in the
--- next checkpoint) never gets the sentence stage: the sentence names B,
--- so the next tap is the full entry behind its confirm (2026-08-25, ref #90).
--- @return table { name, kind, line, body, hint, next_stage }
local function cardContent(hit, opts)
    opts = opts or {}
    if hit.source == "ahead" then
        local name = (type(hit.query) == "string" and hit.query ~= "") and hit.query or hit.name or ""
        local alias_hit = XrayCard.isAliasHit(hit)
        local stage = opts.stage or ((opts.ahead_card == "entry" and not alias_hit) and "sentence" or "name")
        if stage == "name" then
            if alias_hit then
                return { name = name, kind = kindLabel(hit, true), line = aheadLine(hit), warn = true,
                    body = "", hint = _("Tap for the full entry") }
            end
            return { name = name, kind = kindLabel(hit, true), line = aheadLine(hit), warn = true,
                body = "", hint = _("Tap to show a one-line description"), next_stage = "sentence" }
        end
        return { name = name, kind = kindLabel(hit), line = aheadLine(hit), warn = true,
            body = XrayCard.firstSentence(itemText(hit.item)), hint = _("Tap for the full entry") }
    end
    if hit.source == "carried" then
        -- Carried stub (S1): known identity from an earlier book — the
        -- provenance line rides the ahead-warning slot, without the glyph.
        -- S3 parity: the same "Name · Category (role)" head as every other
        -- card (stubs store the role since S3); the line says "Carried from"
        local text = itemText(hit.item)
        if opts.card_length ~= "full" then text = XrayCard.firstSentence(text) end
        return { name = hit.name or "", kind = kindLabel(hit), line = carriedLine(hit),
            body = text, hint = _("Tap for the full entry") }
    end
    if hit.source == "predecessor" then
        -- Earlier book's entry (S2): identity + provenance; the tap-through
        -- opens the read-only predecessor view (buttons live there)
        local text = itemText(hit.item)
        if opts.card_length ~= "full" then text = XrayCard.firstSentence(text) end
        return { name = hit.name or "", kind = kindLabel(hit), line = carriedLine(hit),
            body = text, hint = _("Tap for the full entry") }
    end
    local text = itemText(hit.item)
    if opts.card_length ~= "full" then text = XrayCard.firstSentence(text) end
    return { name = hit.name or "", kind = kindLabel(hit), body = text,
        hint = _("Tap for the full entry") }
end

--- The inside-tap action for a card: advance a staged card in place
--- (close + re-show with the next stage — FootnoteWidget builds its HTML
--- once, and the panel auto-sizes to the grown content, so this reads as
--- an in-place expand) or hand off to the router's full entry.
local function tapAction(hit, opts, content)
    if content.next_stage then
        local next_opts = {}
        for k, v in pairs(opts or {}) do next_opts[k] = v end
        next_opts.stage = content.next_stage
        XrayCard.show(hit, next_opts)
    elseif opts and opts.on_full then
        opts.on_full(hit)
    end
end

--- Resolve an exact entity hit across the live main X-Ray, every section
--- X-Ray, and ONE built checkpoint ahead of the live one (in that order —
--- position truth first, the identification peek last). B269: the peek
--- reads the rung covering the reader's current stretch (the lowest built
--- rung past both live coverage and opts.position), never the newest.
--- @param file string book path
--- @param query string the tapped/selected text
--- @param opts table|nil { include_ahead = false → no peek, position = 0..1 }
--- @return table|nil hit { name, item, category_key, category_label,
---   source = "live"|"section"|"carried"|"predecessor"|"ahead",
---   ahead_progress, query; carried hits add source_title + stub_idx;
---   predecessor hits add source_title (the ORIGINAL book for a transitive
---   ledger hit) + pred_file + pred_title (+ pred_stub); carried and
---   predecessor hits may add also_ahead (Q6 hint, 0..1) }
function XrayCard.resolve(file, query, opts)
    if not file or type(query) ~= "string" or query == "" then return nil end
    local ActionCache = require("koassistant_action_cache")
    local XrayParser = require("koassistant_xray_parser")
    local user_aliases = ActionCache.getUserAliases(file)

    local function findIn(result)
        if type(result) ~= "string" or not XrayParser.isJSON(result) then return nil end
        local data = XrayParser.parse(result)
        if type(data) ~= "table" or data.error then return nil end
        XrayParser.mergeUserAliases(data, user_aliases)
        local results = XrayParser.searchAll(data, query, { exact = true })
        if results and #results > 0 then return results[1] end
    end

    local function makeHit(r, source, ahead_progress)
        return {
            name = XrayParser.getItemName(r.item, r.category_key),
            item = r.item,
            category_key = r.category_key,
            category_label = r.category_label,
            source = source,
            ahead_progress = ahead_progress,
            query = query,
        }
    end

    local live = ActionCache.getXrayCache(file)
    local live_p = 0
    local live_data
    if live and live.result then
        live_p = live.full_document and 1.0 or tonumber(live.progress_decimal) or 0
        if live.source_mode ~= "ai_knowledge" and XrayParser.isJSON(live.result) then
            local data = XrayParser.parse(live.result)
            if type(data) == "table" and not data.error then
                XrayParser.mergeUserAliases(data, user_aliases)
                live_data = data
                local results = XrayParser.searchAll(data, query, { exact = true })
                if results and #results > 0 then return makeHit(results[1], "live") end
            end
        end
    end
    for _idx, sec in ipairs(ActionCache.getSectionXrays(file)) do
        if sec.data and sec.data.result then
            local r = findIn(sec.data.result)
            if r then return makeHit(r, "section") end
        end
    end
    -- One probe for the ahead rung, shared by the final peek tier and the
    -- Q6 hint on carried/predecessor hits ("Also in the next checkpoint").
    -- Respects the Upcoming Entities toggle and needs a position (B269).
    local function aheadProbe()
        if opts and opts.include_ahead == false then return nil end
        local rung = require("koassistant_xray_auto").pickAheadRung(
            ActionCache.getXrayLadder(file), live_p, opts and opts.position)
        if not rung then return nil end
        local r = findIn(rung.result)
        if not r then return nil end
        return r, rung.full_document and 1.0 or tonumber(rung.progress_decimal) or 0
    end
    -- Carried tier (S1 D1, ref #90): the live artifact's own dormant ledger.
    -- An earlier book's knowledge outranks the ahead peek, and the Upcoming
    -- Entities toggle does not gate it (Q8) — already-read content is
    -- spoiler-safe by construction.
    if live_data then
        local stubs = XrayParser.searchLedger(live_data, query, { exact = true })
        if #stubs > 0 then
            local s = stubs[1]
            local hit = {
                name = s.stub.name,
                item = s.stub,
                category_key = s.category_key,
                category_label = XrayParser.categoryLabel(live_data, s.category_key),
                source = "carried",
                source_title = s.source_title,
                stub_idx = s.stub_idx,
                query = query,
            }
            local _ar, ap = aheadProbe()
            hit.also_ahead = ap
            return hit
        end
    end
    -- Group tier (S2 D1/D5 + S4, ref #90): every X-Rayed book the group
    -- lets this book read — earlier books nearest first, then (only while
    -- this book is not under spoiler protection) later books; an unordered
    -- knowledge-sharing group reads every member. Each book answers from
    -- its entries AND its own carried list (a transitive hit reports the
    -- ORIGINAL title). Earlier books rank under everything local and above
    -- the peek; later books rank BELOW the peek — this book's own next
    -- checkpoint sits closer to what the reader is reading than another
    -- book's take.
    local group_list = ActionCache.groupXrays(file)
    local function groupHit(g)
        local results = XrayParser.searchAll(g.data, query, { exact = true })
        if results and #results > 0 then
            local hit = makeHit(results[1], "predecessor")
            hit.source_title = g.title
            hit.pred_file = g.file
            hit.pred_title = g.title
            hit.direction = g.direction
            return hit
        end
        local stubs = XrayParser.searchLedger(g.data, query, { exact = true })
        if #stubs > 0 then
            local s = stubs[1]
            return {
                name = s.stub.name,
                item = s.stub,
                category_key = s.category_key,
                category_label = XrayParser.categoryLabel(g.data, s.category_key),
                source = "predecessor",
                source_title = s.source_title,
                pred_file = g.file,
                pred_title = g.title,
                pred_stub = true,
                direction = g.direction,
                query = query,
            }
        end
        return nil
    end
    for _idx, g in ipairs(group_list) do
        if g.direction ~= "later" then
            local hit = groupHit(g)
            if hit then
                local _ar, ap = aheadProbe()
                hit.also_ahead = ap
                return hit
            end
        end
    end
    -- The identification peek (P5: stood down when the Upcoming Entities
    -- setting is off; B269: the one rung covering the reader's stretch)
    local r, rp = aheadProbe()
    if r then return makeHit(r, "ahead", rp) end
    for _idx, g in ipairs(group_list) do
        if g.direction == "later" then
            local hit = groupHit(g)
            if hit then return hit end
        end
    end
    return nil
end

--- Floating-popup style: the plugin's MinimalPopup, anchored at the tapped
--- word when opts.sboxes carries geometry (EPUB; centered fallback). Tap
--- inside = full entry (the popup's native expand idiom); outside = dismiss.
local function showPopupCard(hit, opts)
    local MinimalPopup = require("koassistant_minimal_popup")
    local ok_v, Viewer = pcall(require, "koassistant_chatgptviewer")
    local can_md = ok_v and Viewer and Viewer.stripMarkdown
    -- Ahead hits: the NAME line leads with the triangle too (device round
    -- 2026-08-17 — the warning line alone sat below where the eye lands)
    local c = cardContent(hit, opts)
    local head = can_md and ("**" .. c.name .. "**") or c.name
    if c.warn then head = "\u{26A0} " .. head end
    if c.kind ~= "" then head = head .. " · " .. c.kind end
    local parts = { head }
    -- Extra line ABOVE the description (2f early placement for the ahead
    -- warning; the carried "From <title>" provenance rides the same slot)
    if c.line then parts[#parts + 1] = c.line end
    if c.body ~= "" then parts[#parts + 1] = c.body end
    -- The staged name-only card says what the tap does (the popup's own
    -- expand affordance is the tap itself)
    if c.next_stage then parts[#parts + 1] = c.hint end
    local text = table.concat(parts, "\n\n")
    local rtl = nil
    if can_md then
        if Viewer.hasDominantRTL and Viewer.hasDominantRTL(text) then rtl = true end
        text = Viewer.stripMarkdown(text, rtl)
    end
    local popup = MinimalPopup:new{
        text = text,
        selection_data = opts.sboxes and { sboxes = opts.sboxes } or nil,
        ui = opts.ui,
        para_direction_rtl = rtl,
        on_expand = function()
            tapAction(hit, opts, c)
        end,
    }
    UIManager:show(popup)
end

--- Footnote-panel style: KOReader's FootnoteWidget (the bottom panel from
--- footnote popups), sized/margined like the book. Tap the panel, swipe
--- west, or Press = full entry; tap outside / swipe south / Back = dismiss.
--- Falls back to the floating popup if construction fails (older KOReader).
local function showFootnoteCard(hit, opts)
    local ok_req, FootnoteWidget = pcall(require, "ui/widget/footnotewidget")
    if not ok_req or not FootnoteWidget then
        return showPopupCard(hit, opts)
    end
    local function esc(s)
        return s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    end
    -- Ahead hits: the NAME line leads with the triangle too (device round
    -- 2026-08-17); the warning line below stays
    local c = cardContent(hit, opts)
    local html = "<div>" .. (c.warn and "\u{26A0} " or "") .. "<b>" .. esc(c.name) .. "</b>"
        .. (c.kind ~= "" and (" · " .. esc(c.kind)) or "") .. "</div>"
    if c.line then
        html = html .. '<div class="koa-meta">' .. esc(c.line) .. "</div>"
    end
    if c.body ~= "" then
        html = html .. '<div class="koa-line">' .. (esc(c.body):gsub("\n", "<br/>")) .. "</div>"
    end
    -- Affordance: stock footnote panels do nothing on an inside tap, ours
    -- advances the card / opens the full entry — say so, muted
    html = html .. '<div class="koa-meta">' .. esc(c.hint) .. "</div>"

    local ui = opts.ui
    local doc = ui and ui.document
    local params = {
        html = html,
        css = ".koa-line { margin-top: 0.4em; } .koa-meta { margin-top: 0.5em; font-size: 80%; color: #555555; }",
        dialog = ui and ui.dialog,
        follow_callback = nil, -- set below (needs the popup upvalue)
    }
    -- The doc_* fields tune the panel to the book (ReaderLink does the same).
    -- Rolling (crengine) docs only: a PDF's configurable.font_size is a
    -- reflow SCALE FACTOR (~1.0), not a point size — paging docs keep the
    -- widget's own defaults instead
    if ui and ui.rolling and doc then
        if ui.font and ui.font.font_face then
            params.doc_font_name = ui.font.font_face
        end
        if doc.configurable and tonumber(doc.configurable.font_size) then
            local Screen = require("device").screen
            params.doc_font_size = Screen:scaleBySize(doc.configurable.font_size)
        end
        if doc.getPageMargins then
            local ok_m, margins = pcall(doc.getPageMargins, doc)
            if ok_m and type(margins) == "table" then
                params.doc_margins = margins
            end
        end
    end
    local popup
    params.follow_callback = function() -- swipe west / Press key
        if popup then UIManager:close(popup) end
        tapAction(hit, opts, c)
    end
    local ok_new
    ok_new, popup = pcall(FootnoteWidget.new, FootnoteWidget, params)
    if not ok_new or type(popup) ~= "table" then
        logger.warn("KOAssistant: footnote card construction failed, falling back to popup style", popup)
        popup = nil
        return showPopupCard(hit, opts)
    end
    -- The card never scrolls (short content) — free the inside tap for the
    -- full-entry action instead of ScrollHtmlWidget's tap-to-scroll zones
    if popup.htmlwidget and popup.htmlwidget.setTapScrollEnabled then
        popup.htmlwidget:setTapScrollEnabled(false)
    end
    popup.onTapClose = function(fw, _arg, ges)
        if ges.pos:notIntersectWith(fw.container.dimen) then
            UIManager:close(fw)
            return true
        end
        UIManager:close(fw)
        tapAction(hit, opts, c)
        return true
    end
    UIManager:show(popup)
end

--- Show the card. opts = { style ("footnote"|"popup"), ui, sboxes,
--- on_full(hit), card_length ("sentence"|"full"), ahead_card ("entry"|"name"),
--- stage (internal: the staged card's current stage) } — on_full opens the
--- full entry (router-owned).
function XrayCard.show(hit, opts)
    opts = opts or {}
    if opts.style == "popup" then
        return showPopupCard(hit, opts)
    end
    return showFootnoteCard(hit, opts)
end

--- Full detail of an AHEAD-only entity: the browser's own body text
--- (XrayParser.formatItemDetail — name/role, aliases, description,
--- connections/significance per category) plus the cross-book background
--- lines, headed by checkpoint provenance. Still a TextViewer host — the
--- browser stack renders the LIVE artifact and cannot hold this entity yet
--- (browser-hosted ahead view = recorded follow-up).
function XrayCard.showFullDetail(hit, fd_opts)
    local TextViewer = require("ui/widget/textviewer")
    local XrayParser = require("koassistant_xray_parser")
    local parts = {}
    -- Same warning line as the cards (round 7: one wording everywhere)
    local ahead = aheadLine(hit)
    if ahead then parts[#parts + 1] = ahead end
    -- Provenance line for earlier-book entries (S2): same wording as the card
    local from = carriedLine(hit)
    if from then parts[#parts + 1] = from end
    local ok_fmt, body = pcall(XrayParser.formatItemDetail, hit.item, hit.category_key)
    if ok_fmt and type(body) == "string" and body:match("%S") then
        parts[#parts + 1] = (body:gsub("%s+$", ""))
    else
        local text = itemText(hit.item)
        if text ~= "" then parts[#parts + 1] = text end
    end
    local item = hit.item or {}
    if type(item.background) == "table" and #item.background > 0 then
        local lines = {}
        for _idx, b in ipairs(item.background) do
            if type(b) == "table" and type(b.text) == "string" and b.text ~= "" then
                local src = (type(b.source) == "string" and b.source ~= "")
                    and (b.source .. ": ") or ""
                lines[#lines + 1] = "• " .. src .. b.text
            end
        end
        if #lines > 0 then
            parts[#parts + 1] = _("From earlier books:") .. "\n" .. table.concat(lines, "\n")
        end
    end
    if #parts == 0 then parts[1] = _("(no description)") end
    local viewer = TextViewer:new{
        title = ahead and ("\u{26A0} " .. (hit.name or "")) or hit.name or "",
        text = table.concat(parts, "\n\n"),
        justified = false,
        buttons_table = fd_opts and fd_opts.buttons_table or nil,
    }
    UIManager:show(viewer)
    return viewer
end

return XrayCard
