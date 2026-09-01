--[[--
Ambient X-Ray marking (A10 slice 2, ref #78): while reading, entities the
book's X-Ray knows are underlined on the page — a passive "this has an entry"
layer with no search session behind it. Tapping a marked word rides the
EXISTING selection intercept (round 9/10) straight to the entity, so this
module paints and nothing else.

Mechanics (donor-verified, xray_marking_plan.md §1/§6; DEFERRED since round 7
— the scan used to run inside the onPageUpdate dispatch and the page turn
WAITED on it, device: "page turns very slow"):
- Paint = ONE `ReaderView:registerViewModule` widget (public API, zero
  patching); dotted DARK_GRAY strip at each box bottom (the maintainer-picked
  ambient default — full invert is an on-demand emphasis style, not this).
- Per page turn: the onPageUpdate handler only CLEARS stale boxes (the fresh
  page must never paint the old page's marks) and schedules the scan for
  SCAN_SETTLE_S after the turn — well after the page's own repaint, and
  rapid flipping never scans at all (each turn invalidates the last
  schedule's token). The scan resolves terms — steady state
  is pure memo lookups (NO page-text read, NO searches); a term never yet
  searched costs one whole-book `findAllText`, so at most ONE runs per tick
  with the rest chained on scheduleIn (UI stays responsive while a
  first-encounter page warms up) — then boxes for current-page hits via
  `getScreenBoxesFromPositions` → dedupe/merge → ONE partial refresh sized
  to the strips, skipped entirely on mark-free pages.
- EPUB page mode only in v1: scroll mode clears (boxes go stale mid-scroll
  with no per-scroll event granularity worth paying for), PDFs are excluded
  (the donor rides the native highlight.temp slot there, which the search
  session also owns — conflict; follow-up).

Spoiler stance (round 5, per the standing round-7 ruling): the LIVE X-Ray is
the marking truth in every posture — installed content already reveals
through its coverage, and demoting to an at-position checkpoint silently
split the mark set from the lookup set (entities added as the X-Ray grew
existed for lookup/tap yet never marked). All section X-Rays fold in,
range-free, for the same one-truth reason. The entity index rebuilds only
when the cache or user-alias sidecar changes on disk (mtime+size stamps —
stats per turn, parses only on change).

State is module-resident and single-book (reader-scoped, like the
Attachments staging list); a different file swaps it wholesale.
]]

local UIManager = require("ui/uimanager")
local logger = require("koassistant_logger")
local lfs = require("libs/libkoreader-lfs")

local XrayMarks = {}

local MODULE_NAME = "koassistant_xray_marks"

-- Marks draw only after the reader SETTLES on a page (round 9, maintainer:
-- rushing through pages shouldn't pay a scan-and-draw per page). Every turn
-- bumps the token; the delayed tick aborts instantly for pages already left,
-- so fast flipping costs nothing — and the page's own repaint always lands
-- well before the marks pass.
local SCAN_SETTLE_S = 0.3

-- st = {
--   file, families (nil = all),
--   spacing,           -- 0 = every occurrence, 1 = once per page, N = only
--                      -- after N pages unseen, math.huge = first appearance
--                      -- only (round 7 "another level of space": the window
--                      -- is measured in reference pages from the entity's
--                      -- nearest PREVIOUS hit, so it is deterministic from
--                      -- book position, not from what the reader viewed)
--   debug,             -- features.debug captured at sync
--   scan_token,        -- bumped per turn; stale deferred ticks abort
--   hits_page_count,   -- doc page count the memo was built against (a
--                      -- re-render, e.g. font change, renumbers pages —
--                      -- wipe the memo, xpointers stay valid)
--   stamps,            -- cache+aliases disk stamp gating the reloads
--   live,              -- in-memory live entry, reloaded on stamp change
--   sections,          -- { {key, sp, ep, stamp, data} } ranges resolved on
--                      -- stamp change; in-range filter per turn is pure
--                      -- arithmetic (round 3: section-only entities were
--                      -- invisible to marking)
--   artifact_key,      -- identity of the artifacts the entity index came from
--   entities,          -- XrayParser.buildMarkEntities output (main + in-range sections)
--   term_hits = {},    -- term text (lower) -> { by_page = {[page] = {{start, e},...}},
--                      -- pages = sorted unique page list } — whole-book,
--                      -- searched at most once per term per session
--   page_marks,        -- current page: { {x,y,w,h, name, text}, ... } — FULL word
--                      -- boxes, the tap targets (round 2, d2)
--   paint_boxes,       -- same-line-merged union rects the strips paint from
--                      -- (round 3: overlapping strips double-painted each
--                      -- other — only a word's tail stayed marked; still
--                      -- wanted for dotted paint so overlapping dot grids
--                      -- never clash)
-- }
local st = nil

-- The paint widget: registerViewModule injects .view/.ui; paintTo runs on
-- every view repaint, so it must only READ prepared state. Style: gray
-- DOTTED underline (maintainer round 7) — quiet enough to live on every
-- page, distinct from KOReader's solid-underline highlight style, and
-- paintRect (unlike the old invertRect) never self-cancels on overlap.
-- AHEAD-ONLY entities (known only to the newest built checkpoint — round
-- 16) paint short DASHES instead: same gray, same weight, visibly "new /
-- identification only", so the reader knows the full entry sits behind the
-- spoiler gate before tapping.
local paint_widget = {
  paintTo = function(_w, bb, _x, _y)
    local boxes = st and st.paint_boxes
    if not boxes then return end
    local Screen = require("device").screen
    local Blitbuffer = require("ffi/blitbuffer")
    local strip = math.max(2, Screen:scaleBySize(2))
    local dot = math.max(3, Screen:scaleBySize(3))
    local dash = math.max(7, Screen:scaleBySize(7))
    local gap = math.max(2, Screen:scaleBySize(2))
    for _i, box in ipairs(boxes) do
      if box.x and box.y and box.w and box.h and box.w > 0 and box.h > strip then
        local seg = box.ahead and dash or dot
        local y = box.y + box.h - strip
        local x_end = box.x + box.w
        local x = box.x
        while x < x_end do
          bb:paintRect(x, y, math.min(seg, x_end - x), strip,
            Blitbuffer.COLOR_DARK_GRAY)
          x = x + seg + gap
        end
      end
    end
  end,
}

--- Disk stamp over everything the entity index depends on. Stats only.
--- The ladder joins (point-4): the index folds the newest built checkpoint
--- ahead of the live artifact, so a fresh rung must re-index.
local function diskStamps(ActionCache, file)
  local parts = {}
  local cache_path = ActionCache.getPath(file)
  local attr = cache_path and lfs.attributes(cache_path)
  parts[#parts + 1] = attr and (tostring(attr.modification) .. ":" .. tostring(attr.size)) or "-"
  local apath = ActionCache.getUserAliasesPath(file)
  local aattr = apath and lfs.attributes(apath)
  parts[#parts + 1] = aattr and (tostring(aattr.modification) .. ":" .. tostring(aattr.size)) or "-"
  local lpath = ActionCache.getXrayLadderPath and ActionCache.getXrayLadderPath(file)
  local lattr = lpath and lfs.attributes(lpath)
  parts[#parts + 1] = lattr and (tostring(lattr.modification) .. ":" .. tostring(lattr.size)) or "-"
  return table.concat(parts, "|")
end

--- The artifact behind the marks: the LIVE X-Ray, always (round 5). The
--- earlier draft demoted to a ladder checkpoint at-or-below the reading
--- position under spoiler protection — but that contradicts the standing
--- round-7 ruling ("installed content already reveals through its coverage;
--- a complete install reveals everything"), and it silently split the mark
--- set from the lookup set: entities added as the X-Ray grew (the minor
--- ones) existed for lookup/tap yet never marked. Installed = revealed;
--- marked = findable, one truth. ai_knowledge/non-JSON lineages never mark.
local function pickArtifact()
  local XrayParser = require("koassistant_xray_parser")
  local live = st.live
  if not (live and live.result) or live.source_mode == "ai_knowledge"
      or not XrayParser.isJSON(live.result) then
    return nil
  end
  return live
end

--- Reload disk state on stamp change, re-pick the artifacts, rebuild the
--- entity index when the pick changed. Cheap when nothing moved.
local function ensureIndex(plugin, pageno)
  local ActionCache = require("koassistant_action_cache")
  local stamps = diskStamps(ActionCache, st.file)
  if stamps ~= st.stamps then
    st.stamps = stamps
    st.live = ActionCache.getXrayCache(st.file)
    -- Section X-Rays (round 3): entities that live only in a section were
    -- invisible to marking while every LOOKUP surface searches sections
    -- too. Ranges resolve once per disk change (the real resolver — an
    -- exclusive end xpointer and last-section/hidden-flow handling live
    -- there); the per-turn in-range filter is pure arithmetic.
    st.sections = {}
    local doc = plugin.ui and plugin.ui.document
    for _idx, sec in ipairs(ActionCache.getSectionXrays(st.file)) do
      if sec.data and sec.data.result then
        local okr, sp, ep = pcall(ActionCache.getSectionPageRange, sec.data, doc)
        if okr and sp and ep then
          st.sections[#st.sections + 1] = { key = sec.key, sp = sp, ep = ep,
            stamp = tostring(sec.data.timestamp), data = sec.data }
        end
      end
    end
    -- Point-4 identification peek: the newest built checkpoint AHEAD of the
    -- live artifact joins the index, so entities that first appear past the
    -- installed coverage get marked (and card-identified) when the reader
    -- meets them. Full entries stay position-gated in the card router.
    -- P5: the Upcoming Entities setting stands the peek down (default on);
    -- with it off the key drops its "|ahead:" part, so a flip rebuilds the
    -- index on the next sync/scan by itself. Round 3: book override > global
    -- via the marking resolver, like the other marking keys.
    -- B269: the ladder is loaded once per disk change; the ONE rung the
    -- peek may read is re-picked below on every call, from the reader's
    -- position (pure arithmetic — the index key carries the pick, so a
    -- page turn into the next checkpoint's stretch rebuilds by itself)
    st.ladder = nil
    local marks_feats = plugin.settings and plugin.settings:readSetting("features") or {}
    if require("koassistant_book_settings").resolveXrayMarking(
        plugin.ui and plugin.ui.doc_settings, marks_feats).ahead then
      st.ladder = ActionCache.getXrayLadder(st.file)
    end
  end
  st.ahead = nil
  if st.ladder and #st.ladder > 0 then
    local live_p = st.live and (st.live.full_document and 1.0
      or tonumber(st.live.progress_decimal)) or 0
    local total = plugin.ui and plugin.ui.document and plugin.ui.document.info
      and plugin.ui.document.info.number_of_pages
    local position = (pageno and total and total > 0) and (pageno / total) or nil
    local rg = require("koassistant_xray_auto").pickAheadRung(st.ladder, live_p, position)
    if rg then
      st.ahead = { result = rg.result, stamp = tostring(rg.timestamp),
        p = rg.full_document and 1.0 or tonumber(rg.progress_decimal) or 0 }
    end
  end
  local art = pickArtifact()
  -- Predecessor tier (S2 Q4, ref #90): the nearest earlier X-Rayed book in
  -- the group marks too — marked = findable, and the lookup/route surfaces
  -- now answer from it. Memoized inside ActionCache (stamp-keyed), so the
  -- steady-state cost here is stats, not parses. A book with NO artifacts
  -- of its own still marks its predecessor's entities (the "never X-Rayed
  -- this volume" case).
  local pred = ActionCache.nearestPredecessorXray(st.file)
  -- Round 5: ALL section X-Rays fold in, range-free — the lookup/intercept
  -- surfaces search every section regardless of range (searchAllXrays), so
  -- a section-only entity was findable-but-never-marked outside its span
  -- (device: ents jumped 153→181 across a section boundary while "Danny
  -- Lloyd" matched lookups everywhere and marks nowhere). Marked = findable,
  -- one truth; the spoiler angle is covered by the round-7 ruling (installed
  -- content reveals through its coverage — sections are installed content).
  if not art and #(st.sections or {}) == 0 and not pred then
    st.entities = nil
    st.artifact_key = nil
    return
  end
  local key = art and (tostring(art.timestamp) .. "|" .. tostring(art.progress_decimal)) or "-"
  for _idx, s in ipairs(st.sections or {}) do
    key = key .. "|" .. s.key .. ":" .. s.stamp
  end
  if st.ahead then
    key = key .. "|ahead:" .. st.ahead.stamp
  end
  key = key .. "|" .. st.stamps
  key = key .. "|pred:" .. (pred and pred.stamp or "-")
  if st.artifact_key == key and st.entities then return end
  local XrayParser = require("koassistant_xray_parser")
  local user_aliases = ActionCache.getUserAliases(st.file)
  local ents = {}
  local seen_names = {}
  local included, skipped = {}, {}
  local function addFrom(result, is_ahead)
    local data = XrayParser.parse(result)
    if not data then return end
    XrayParser.mergeUserAliases(data, user_aliases)
    for _idx, e in ipairs(XrayParser.buildMarkEntities(data)) do
      -- First writer wins across sources (main → sections → ahead): the
      -- ahead rung contributes only entities the position truth lacks
      local nk = type(e.name) == "string" and e.name:lower() or nil
      if not (nk and seen_names[nk]) then
        if nk then seen_names[nk] = true end
        -- Ahead-only entities paint differently (dashes) — the reader can
        -- tell "new, identification only" from an established mark
        if is_ahead then e.ahead = true end
        ents[#ents + 1] = e
        included[e.category_key] = (included[e.category_key] or 0) + 1
      end
    end
    -- Tally what the category gate dropped — the one line that separates
    -- "entity in a non-marking category" from "entity not in this artifact"
    -- on the next logged round
    for _idx, cat in ipairs(XrayParser.getCategories(data) or {}) do
      if XrayParser.TEXT_MATCH_EXCLUDED[cat.key] and #cat.items > 0 then
        skipped[cat.key] = (skipped[cat.key] or 0) + #cat.items
      end
    end
    return data
  end
  local main_data
  if art then main_data = addFrom(art.result) end
  for _idx, s in ipairs(st.sections or {}) do addFrom(s.data.result) end
  -- Carried tier (S1 D1/Q1, ref #90): the ledger's stubs mark DOTTED like
  -- live entities — the identity is known and spoiler-safe — and OUTRANK the
  -- ahead peek (first-writer-wins keeps an ahead duplicate from re-tagging
  -- a carried name as dashed). Position in this chain: after the position
  -- truth (main + sections), before the peek.
  if main_data then
    for _idx, e in ipairs(XrayParser.buildLedgerMarkEntities(main_data)) do
      local nk = type(e.name) == "string" and e.name:lower() or nil
      if not (nk and seen_names[nk]) then
        if nk then seen_names[nk] = true end
        ents[#ents + 1] = e
        included[e.category_key] = (included[e.category_key] or 0) + 1
      end
    end
  end
  -- Predecessor tier (S2 Q4, ref #90): the nearest earlier book's entities
  -- and ITS carried list mark DOTTED like live ones (already-read content;
  -- the card carries the "From <title>" provenance). After every local
  -- source, before the peek — a local duplicate keeps its own style.
  if pred then
    for _idx, e in ipairs(XrayParser.buildMarkEntities(pred.data)) do
      local nk = type(e.name) == "string" and e.name:lower() or nil
      if not (nk and seen_names[nk]) then
        if nk then seen_names[nk] = true end
        ents[#ents + 1] = e
        included[e.category_key] = (included[e.category_key] or 0) + 1
      end
    end
    for _idx, e in ipairs(XrayParser.buildLedgerMarkEntities(pred.data)) do
      local nk = type(e.name) == "string" and e.name:lower() or nil
      if not (nk and seen_names[nk]) then
        if nk then seen_names[nk] = true end
        ents[#ents + 1] = e
        included[e.category_key] = (included[e.category_key] or 0) + 1
      end
    end
  end
  if st.ahead then addFrom(st.ahead.result, true) end
  -- Cross-entity containment (B266): an entity whose term sits inside
  -- another entity's longer handle ("Kubrick" in "Vivian Kubrick") records
  -- those entities; the paint pass drops its hits that lie inside theirs.
  -- Index-time only, so the per-turn scan pays nothing for it.
  for i, a in ipairs(ents) do
    local longer
    for j, b in ipairs(ents) do
      if i ~= j then
        local hit = false
        for _ta, ta in ipairs(a.terms) do
          for _tb, tb in ipairs(b.terms) do
            if XrayParser.handleContainsWord(tb.norm, ta.norm) then
              hit = true
              break
            end
          end
          if hit then break end
        end
        if hit then
          longer = longer or {}
          longer[#longer + 1] = b.name
        end
      end
    end
    a.longer = longer
  end
  st.entities = #ents > 0 and ents or nil
  st.artifact_key = key
  local function tally(t)
    local parts = {}
    for k, v in pairs(t) do parts[#parts + 1] = k .. "=" .. v end
    table.sort(parts)
    return table.concat(parts, " ")
  end
  local src = "none"
  if art then
    local pct = art.full_document and 100
        or math.floor((tonumber(art.progress_decimal) or 0) * 100 + 0.5)
    src = (art == st.live and "live@" or "checkpoint@") .. pct .. "%"
  end
  logger.dbg("KOAssistant marks: index rebuilt from " .. src
    .. " +" .. tostring(#(st.sections or {})) .. " sections"
    .. (pred and " +pred" or "")
    .. (st.ahead and (" +ahead@" .. math.floor(st.ahead.p * 100 + 0.5) .. "%") or "")
    .. ": " .. tally(included)
    .. (next(skipped) and (" | skipped: " .. tally(skipped)) or ""))
end

-- Word-boundary honesty for plain terms (round 3, device: an entity name
-- marked inside a longer word containing it): crengine's own word
-- segmentation arrives as matched_word_prefix/suffix — leftover LETTERS in
-- the same word mean a mid-word substring match, dropped for marking.
-- Possessive tails ('s) and pure punctuation stay markable (a possessive
-- "name's" must mark). Arabic regex
-- terms are exempt: their pattern already consumes article/diacritic
-- variants, and attached-prefix morphology needs the looseness.
local function blockingAffix(s)
  if not s or s == "" then return false end
  if s == "'s" or s == "\226\128\153s" then return false end
  if s:find("%a") or s:find("[\128-\255]") then return true end
  return false
end

--- B265: crengine reports a suffix for any match that does not end on a
--- visible word end, so a term ending in punctuation ("D.B.", "Jr.") gets
--- the NEXT word as its suffix on every occurrence and was never marked.
--- When the term's own edge is a non-word char, the affix on that side
--- describes a neighbour, not a mid-word leftover; ignore it.
local function edgeIsWordChar(term_text, side)
  local ch = side == "prefix" and term_text:sub(1, 1) or term_text:sub(-1)
  return ch ~= "" and (ch:find("%w") ~= nil or ch:find("[\128-\255]") ~= nil)
end

--- Whole-doc hit index for one term: hits bucketed per page plus the sorted
--- page list (the spacing window walks it for the nearest previous hit).
--- Memoized by the caller; runs at most once per term per session — this is
--- THE expensive call (whole-book search), which is why the scan chain
--- budgets it to one per tick.
--- Search flags are LOAD-BEARING (round 4, a styled two-word name went
--- unmarked):
--- without them crengine matches nothing across DOM text-node boundaries
--- (MATCH_ACROSS_TEXT_NODES) and folds no NBSP/soft-hyphen/curly-apostrophe
--- (FOLD_* / IGNORE_FORMAT_CONTROL_CHARS) — a styled or NBSP-joined name
--- passes the page-TEXT presence check yet returns zero search hits, and
--- the empty result memoizes. 0x00FF = stock's default-search flag set;
--- regex rides 0x0001 exactly like stock's regex search type.
local function searchTerm(document, term)
  local res
  if term.regex then
    res = document:findAllText(term.regex, true, 1, 2000, true, 0x0001)
  else
    res = document:findAllText(term.text, true, 1, 2000, false, 0x00FF)
  end
  local by_page, pages = {}, {}
  if res then
    for _i, r in ipairs(res) do
      local keep = true
      if not term.regex
          and ((edgeIsWordChar(term.text, "prefix") and blockingAffix(r.matched_word_prefix))
            or (edgeIsWordChar(term.text, "suffix") and blockingAffix(r.matched_word_suffix))) then
        keep = false
      end
      if keep then
        local ok, page = pcall(document.getPageFromXPointer, document, r.start)
        if ok and page then
          local bucket = by_page[page]
          if not bucket then
            bucket = {}
            by_page[page] = bucket
            pages[#pages + 1] = page
          end
          bucket[#bucket + 1] = { start = r.start, e = r["end"] }
        end
      end
    end
  end
  table.sort(pages)
  return { by_page = by_page, pages = pages }
end

local function dedupeMarks(marks)
  local seen, out = {}, {}
  for _i, b in ipairs(marks) do
    local k = tostring(b.x) .. "|" .. tostring(b.y) .. "|" .. tostring(b.w)
    if not seen[k] then
      seen[k] = true
      out[#out + 1] = b
    end
  end
  return out
end

-- Union overlapping same-line boxes into single paint rects (round 3):
-- invertRect is self-cancelling, so two entities matching overlapping spans
-- (Arabic article variants, main+section duplicates) XOR each other back to
-- normal — the only-the-word-tail-marked artifact. Tap targets
-- keep the raw per-entity boxes; only the painted strips merge.
local function mergeLineBoxes(marks)
  local rows = {}
  for _i, m in ipairs(marks) do
    local placed = false
    for _j, row in ipairs(rows) do
      if math.abs(row.y - m.y) < math.max(row.h, m.h) / 2 then
        row.boxes[#row.boxes + 1] = m
        placed = true
        break
      end
    end
    if not placed then
      rows[#rows + 1] = { y = m.y, h = m.h, boxes = { m } }
    end
  end
  local out = {}
  for _i, row in ipairs(rows) do
    table.sort(row.boxes, function(a, b) return a.x < b.x end)
    local cur
    for _j, b in ipairs(row.boxes) do
      if cur and b.x <= cur.x + cur.w then
        local right = math.max(cur.x + cur.w, b.x + b.w)
        local bottom = math.max(cur.y + cur.h, b.y + b.h)
        cur.y = math.min(cur.y, b.y)
        cur.w = right - cur.x
        cur.h = bottom - cur.y
        -- A merged strip stays "ahead" (dashed) only when EVERY contributor
        -- is — an established mark makes the whole strip established
        cur.ahead = cur.ahead and b.ahead or nil
      else
        cur = { x = b.x, y = b.y, w = b.w, h = b.h, ahead = b.ahead }
        out[#out + 1] = cur
      end
    end
  end
  return out
end

--- One deferred scan step (round 7 — the perf split). Resolve phase: a term
--- present on this page but never searched costs one whole-book findAllText
--- (~100ms+ on device), so at most ONE runs per tick and the rest chain on
--- scheduleIn; the normalized page text (hay) is built lazily on the first
--- unsearched term and carried through the chain. Paint phase (every term
--- memoized — the steady state): page hits are pure table lookups, boxes
--- resolve for this page only, then ONE partial refresh sized to the strips
--- — a mark-free page schedules nothing and refreshes nothing.
function XrayMarks._scanTick(plugin, pageno, token, hay)
  if not st or st.scan_token ~= token then return end
  local ui = plugin and plugin.ui
  if not (ui and ui.document and ui.rolling) then return end
  if ui.document.file ~= st.file then return end
  if ui.view and ui.view.view_mode == "scroll" then return end
  -- A search session can OPEN between the turn and this tick (or mid-chain
  -- during a multi-term warm-up) — our findAllText would erase its hit
  -- highlights (the round-3 bug), so every tick re-checks
  local search = ui.search
  if search and (search._koassistant_search_session
      or (search.search_dialog and UIManager:isWidgetShown(search.search_dialog))) then
    return
  end
  local ok, err = pcall(function()
    local time = require("ui/time")
    local t0 = time.now()
    ensureIndex(plugin, pageno)
    if not st.entities or #st.entities == 0 then return end
    local idx_ms = time.to_ms(time.now() - t0)
    local hay_ms = 0

    -- A re-render (font/margin change) renumbers pages; the memo's pages
    -- were computed against the old flow. Xpointers stay valid — only the
    -- page bucketing is stale — so wipe and let terms re-search on demand.
    local total = ui.document.info and ui.document.info.number_of_pages
    if total and st.hits_page_count ~= total then
      if st.hits_page_count ~= nil then st.term_hits = {} end
      st.hits_page_count = total
    end

    -- Resolve: first present-but-never-searched term searches now, rest of
    -- the chain follows one tick at a time. An absent unsearched term stays
    -- unmemoized on purpose — the page where it IS present triggers its
    -- one-time search.
    for _i, ent in ipairs(st.entities) do
      if not st.families or st.families[ent.family] then
        for _j, term in ipairs(ent.terms) do
          local tkey = term.text:lower()
          if not st.term_hits[tkey] then
            if hay == nil then
              -- Visible-page text, once per scan (page-level read, same
              -- consent class as the page-exempt extraction). LAYOUT text:
              -- line wraps arrive as newlines, so a wrapped "Danny\nLloyd"
              -- must still match the single-space term — collapse all
              -- whitespace (NBSP included) like the term norms.
              local hay_t = time.now()
              local ContextExtractor = require("koassistant_context_extractor")
              local XrayParser = require("koassistant_xray_parser")
              local page_text = ContextExtractor:new(ui):getVisiblePageText().text or ""
              hay = XrayParser.normalizeArabic(page_text:lower())
                  :gsub("\194\160", " "):gsub("%s+", " ")
              hay_ms = time.to_ms(time.now() - hay_t)
            end
            if hay ~= "" and hay:find(term.norm, 1, true) then
              local search_t = time.now()
              st.term_hits[tkey] = searchTerm(ui.document, term)
              if st.debug then
                logger.info("KOAssistant marks dbg: searched \"" .. term.text
                  .. "\" -> " .. tostring(#st.term_hits[tkey].pages)
                  .. " pages in "
                  .. string.format("%.0f", time.to_ms(time.now() - search_t)) .. "ms")
              end
              UIManager:scheduleIn(0.05, function()
                XrayMarks._scanTick(plugin, pageno, token, hay)
              end)
              return
            end
          end
        end
      end
    end

    -- Paint: entity-level spacing + box resolution from the memo
    local paint_t = time.now()
    local dbg = st.debug and { marked = {} } or nil
    local marks = {}
    -- Pass 1: hits on this page per entity (pageno+1 covers two-page
    -- spreads) and, for the spacing window, the entity's nearest hit page
    -- BEFORE this page
    local per_ent, hits_by_name = {}, {}
    for _i, ent in ipairs(st.entities) do
      if not st.families or st.families[ent.family] then
        local page_hits = {}
        local prev_page
        for _j, term in ipairs(ent.terms) do
          local th = st.term_hits[term.text:lower()]
          if th then
            for p = pageno, pageno + 1 do
              local bucket = th.by_page[p]
              if bucket then
                for _k, h in ipairs(bucket) do
                  -- The matched TEXT rides with the hit: a mark tap must
                  -- open the card on the words the reader tapped, never on
                  -- the entry name (an alias mark printing the entry name
                  -- revealed the alias link on sight)
                  page_hits[#page_hits + 1] = { h = h, text = term.text }
                end
              end
            end
            if st.spacing > 1 then
              local pgs = th.pages
              for k = #pgs, 1, -1 do
                if pgs[k] < pageno then
                  if not prev_page or pgs[k] > prev_page then prev_page = pgs[k] end
                  break
                end
              end
            end
          end
        end
        per_ent[#per_ent + 1] = { ent = ent, hits = page_hits, prev_page = prev_page }
        hits_by_name[ent.name] = page_hits
      end
    end
    -- Pass 2: containment (B266) — a hit lying inside a longer entity's hit
    -- on this page is that entity's mention (xpointer range comparison on
    -- the memo, no box work); then spacing + boxes
    for _i, pe in ipairs(per_ent) do
      local ent, page_hits, prev_page = pe.ent, pe.hits, pe.prev_page
      if ent.longer and #page_hits > 0 then
        local kept = {}
        for _k, ph in ipairs(page_hits) do
          local inside = false
          for _l, lname in ipairs(ent.longer) do
            for _m, lh in ipairs(hits_by_name[lname] or {}) do
              local ok1, c1 = pcall(ui.document.compareXPointers, ui.document, lh.h.start, ph.h.start)
              local ok2, c2 = pcall(ui.document.compareXPointers, ui.document, ph.h.e, lh.h.e)
              if ok1 and ok2 and c1 and c2 and c1 >= 0 and c2 >= 0 then
                inside = true
                break
              end
            end
            if inside then break end
          end
          if not inside then kept[#kept + 1] = ph end
        end
        page_hits = kept
      end
      do
        -- Spacing window: the entity appeared within the last N pages —
        -- stay quiet (math.huge = first appearance only). Measured from
        -- book positions, so it is deterministic under back-jumps too.
        local suppressed = #page_hits > 0 and st.spacing > 1 and prev_page
            and (pageno - prev_page) < st.spacing
        if #page_hits > 0 and not suppressed then
          local ent_done = false
          for _k, ph in ipairs(page_hits) do
            local h = ph.h
            -- Off-view positions return no/off-screen boxes; y-filter drops
            local bok, bxs = pcall(ui.document.getScreenBoxesFromPositions,
              ui.document, h.start, h.e, true)
            if bok and bxs then
              local added = false
              for _b, box in ipairs(bxs) do
                if box.y and box.y >= 0 and box.h and box.h > 0 then
                  marks[#marks + 1] = { x = box.x, y = box.y,
                    w = box.w, h = box.h, name = ent.name,
                    text = ph.text, ahead = ent.ahead }
                  added = true
                end
              end
              if added then ent_done = true end
            end
            -- Any spacing except "every occurrence": one mark per entity
            if st.spacing >= 1 and ent_done then break end
          end
          if dbg and ent_done then table.insert(dbg.marked, ent.name) end
        end
      end
    end
    if #marks > 0 then
      st.page_marks = dedupeMarks(marks)
      st.paint_boxes = mergeLineBoxes(st.page_marks)
    end
    -- Phase-split timing line (the round-9 device-slowness arbiter). The
    -- old full-hay dump is GONE — multi-KB synchronous log writes per page
    -- turn were themselves a device cost, and its forensic job (presence
    -- replay) is done. `text` covers page read+normalize, the presence
    -- finds are total minus the named phases.
    if dbg then
      logger.info("KOAssistant marks dbg: page " .. tostring(pageno)
        .. " ents=" .. tostring(#st.entities)
        .. " marked=[" .. table.concat(dbg.marked, ", ") .. "]"
        .. " boxes=" .. tostring(st.page_marks and #st.page_marks or 0)
        .. " idx=" .. string.format("%.0f", idx_ms)
        .. "ms text=" .. string.format("%.0f", hay_ms)
        .. "ms paint=" .. string.format("%.0f", time.to_ms(time.now() - paint_t))
        .. "ms total=" .. string.format("%.0f", time.to_ms(time.now() - t0)) .. "ms")
    end
    -- One targeted partial refresh over the union of the strips — except
    -- after a settings change (sync sets full_refresh), where the whole
    -- page repaints once so removed marks can't linger outside the region
    if st.full_refresh and ui.dialog then
      st.full_refresh = nil
      UIManager:setDirty(ui.dialog, "ui")
    elseif st.paint_boxes and ui.dialog then
      local Geom = require("ui/geometry")
      local first = st.paint_boxes[1]
      local rx, ry = first.x, first.y
      local rx2, ry2 = first.x + first.w, first.y + first.h
      for _b = 2, #st.paint_boxes do
        local b = st.paint_boxes[_b]
        rx = math.min(rx, b.x)
        ry = math.min(ry, b.y)
        rx2 = math.max(rx2, b.x + b.w)
        ry2 = math.max(ry2, b.y + b.h)
      end
      UIManager:setDirty(ui.dialog, "ui", Geom:new{
        x = math.floor(rx), y = math.floor(ry),
        w = math.ceil(rx2 - rx), h = math.ceil(ry2 - ry),
      })
    end
  end)
  if not ok then
    logger.warn("KOAssistant marks: scan failed:", err)
    st.page_marks = nil
    st.paint_boxes = nil
  end
end

--- Per-page-turn entry. Called from AskGPT:onPageUpdate (inside the
--- dispatch, BEFORE the repaint) and from sync() for the current page.
--- Synchronous work is only what must not wait: clearing stale boxes (the
--- fresh page must never paint the old page's marks) and the search-session
--- state machine; the actual scan runs SCAN_SETTLE_S after the turn (round
--- 7 moved it off the dispatch — the turn waited on searches and boxes;
--- round 9 added the settle so rapid flipping pays nothing per page).
function XrayMarks.onPageTurn(plugin, pageno)
  if not st then return end
  local ui = plugin and plugin.ui
  if not (ui and ui.document and ui.rolling and pageno) then return end
  if ui.document.file ~= st.file then return end
  st.page_marks = nil
  st.paint_boxes = nil
  if ui.view and ui.view.view_mode == "scroll" then return end

  -- A live search session owns the page visuals: our findAllText shares
  -- crengine's selection state with the session's hit highlighting, so a
  -- scan mid-session ERASES the highlights (round 3, device: "hits are no
  -- longer highlighted"). The session flag is set by the onShowSearchDialog
  -- wrap BEFORE the initial jump (do_search runs before UIManager:show, so
  -- isWidgetShown alone misses the first hit); once the dialog has been
  -- seen shown, its close ends the session and marks resume.
  local search = ui.search
  local sd = search and search.search_dialog
  if sd and UIManager:isWidgetShown(sd) then
    search._koassistant_search_session = "shown"
    -- Invalidate any in-flight scan chain too
    st.scan_token = (st.scan_token or 0) + 1
    return
  end
  local sess = search and search._koassistant_search_session
  if sess == true then
    st.scan_token = (st.scan_token or 0) + 1
    return
  elseif sess then
    -- Was shown, now closed: session over
    search._koassistant_search_session = nil
  end

  st.scan_token = (st.scan_token or 0) + 1
  local token = st.scan_token
  UIManager:scheduleIn(SCAN_SETTLE_S, function()
    XrayMarks._scanTick(plugin, pageno, token, nil)
  end)
end

--- d2 tap layer (round 2): entity name under a tap, or nil. The FULL word
--- box is the target (the painted strip alone would be a sliver); small
--- padding helps e-ink finger accuracy. Gated on the tap setting per call.
--- @param plugin table AskGPT instance
--- @param ges table Tap gesture ({pos = {x, y}})
--- @return string|nil entity name
--- @return table|nil word box {x, y, w, h} (screen coords, fresh copy) —
---   anchors the floating-popup card style
function XrayMarks.tapTarget(plugin, ges)
  local marks = st and st.page_marks
  if not (marks and ges and ges.pos) then return nil end
  local features = plugin and plugin.settings
      and plugin.settings:readSetting("features") or {}
  -- Book override > global (2026-08-15: the popup's quick settings write the
  -- book layer; sidecar reads are memory-cached, so this stays a cheap tap)
  local marking = require("koassistant_book_settings").resolveXrayMarking(
      plugin and plugin.ui and plugin.ui.doc_settings, features)
  if not marking.tap then return nil end
  local Screen = require("device").screen
  local pad = Screen:scaleBySize(3)
  local tx, ty = ges.pos.x, ges.pos.y
  for _i, m in ipairs(marks) do
    if tx >= m.x - pad and tx <= m.x + m.w + pad
        and ty >= m.y - pad and ty <= m.y + m.h + pad then
      -- The tapped TEXT (name or alias as it stands in the book), so the
      -- card resolves it like a long-press would and shows what was tapped
      return m.text or m.name, { x = m.x, y = m.y, w = m.w, h = m.h }
    end
  end
  return nil
end

--- Install/refresh/remove per settings + book state. Call on reader ready,
--- setting changes, and whenever a surface wants marks to reflect NOW.
function XrayMarks.sync(plugin)
  local ui = plugin and plugin.ui
  local features = plugin and plugin.settings
      and plugin.settings:readSetting("features") or {}
  -- Opt-out since round 10 (default ON — read pattern must match the schema
  -- default): nil counts as enabled, explicit false is the opt-out.
  -- 2026-08-15: book override > global (the X-Ray popup's quick settings
  -- write the book layer, Settings menu stays the global default)
  local marking = require("koassistant_book_settings").resolveXrayMarking(
      ui and ui.doc_settings, features)
  local eligible = marking.enabled
      and ui and ui.document and ui.rolling and ui.view
  if not eligible then
    XrayMarks.teardown(plugin)
    return
  end

  if not (st and st.file == ui.document.file) then
    st = { file = ui.document.file, term_hits = {} }
  end
  -- Density → spacing (round 7): "all" marks every occurrence, "first" once
  -- per page, "10"/"25" only after that many pages unseen, "once" only the
  -- first appearance in the book. Default flipped to "10" round 9 —
  -- returning names stand out, constant companions stay quiet.
  local density = marking.density
  if density == "all" then
    st.spacing = 0
  elseif density == "once" then
    st.spacing = math.huge
  else
    st.spacing = tonumber(density) or 1
  end
  st.debug = features.debug and true or nil
  -- Settings changed: the next completed scan must repaint the WHOLE page —
  -- its region refresh is sized to the NEW marks, and a mode change that
  -- shrinks the set would leave removed marks visible outside it
  st.full_refresh = true
  local fam = marking.families
  if fam == "people" then
    st.families = { people = true }
  elseif fam == "people_places" then
    st.families = { people = true, places = true }
  else
    st.families = nil
  end
  -- Settings may have changed what the index feeds on — force a re-pick.
  -- st.stamps too (P5 device round): the sections + ahead-rung snapshot only
  -- refreshes when file stamps change, so a flip of the Upcoming Entities
  -- setting kept the STALE st.ahead until the book was reopened.
  st.artifact_key = nil
  st.stamps = nil

  if not ui.view.view_modules[MODULE_NAME] then
    ui.view:registerViewModule(MODULE_NAME, paint_widget)
  end
  local okp, pageno = pcall(ui.document.getCurrentPage, ui.document)
  XrayMarks.onPageTurn(plugin, okp and pageno or nil)
  if ui.dialog then
    UIManager:setDirty(ui.dialog, "ui")
  end
end

function XrayMarks.teardown(plugin)
  local ui = plugin and plugin.ui
  local was_painting = st and st.paint_boxes
  st = nil
  if ui and ui.view and ui.view.view_modules
      and ui.view.view_modules[MODULE_NAME] then
    ui.view.view_modules[MODULE_NAME] = nil
    if was_painting and ui.dialog then
      UIManager:setDirty(ui.dialog, "ui")
    end
  end
end

return XrayMarks
