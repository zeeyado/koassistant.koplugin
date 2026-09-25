--[[--
Per-book X-Ray name index (docs/xray_marks_freeze_plan.md, round 4): where
every X-Ray name form occurs in the book, page by page, at one layout. One
pass reads every page's text once and finds every form with the one text
matcher (XrayParser.matchNormalize + _collectMatchSpans), in a background
process niced below the reader; Chapter Appearances, the Mentions view and
the marks' spacing read the result instead of searching the whole book.

Keyed by FORM (a normalized name or alias), not by X-Ray: the main X-Ray,
its checkpoints, section X-Rays, carried and group names share forms, and
versions get archived and swapped. A form nobody asks for any more is simply
not read; new forms are found by one pass for all of them together; a
layout change (font, size, margins, spacing, rotation) renumbers the pages,
so that layout gets its own entry, found again in the background. Two
layouts are kept (portrait and landscape readers flip between them).

File <sidecar>/koassistant_xray_index.lua:
  { version = 1, layouts = { { stamp = "<rendering hash>:<pages>:<size>",
    forms = { [form] = "<page delta>:<offset>.<offset>,..." } }, ... } }
Offsets are byte starts in that page's normalized text, so an entity's
occurrences (union of its forms, minus containment) are exact at query time,
the same rule as XrayParser.occurrencesIn.
]]

local UIManager = require("ui/uimanager")
local logger = require("koassistant_logger")
local lfs = require("libs/libkoreader-lfs")
local XrayParser = require("koassistant_xray_parser")
local _ = require("koassistant_gettext")

local XrayIndex = {}

XrayIndex.FILE = "koassistant_xray_index.lua"
local VERSION = 1
local MAX_LAYOUTS = 2
-- A background request waits this long (debounced) before its pass starts:
-- the book's own opening work and the first page turns go first
local START_DELAY_S = 5
local POLL_S = 1
-- A section's own span is read in process up to this many pages (a fraction
-- of a second on an e-reader); longer ranges go through a subprocess
XrayIndex.IN_PROCESS_PAGES = 120

-- path -> { data = table|false } (false = no file). Only this module writes
-- the file, so the memo is authoritative once loaded.
local loaded = {}
-- The pending request for the open book: { file, ui, forms = set, listeners }
local pending = nil
-- The one background pass: { file, stamp, forms = set, pid, read_fd, cancelled }
local running = nil

--- crengine documents only: page-mode EPUB/FB2/HTML… (PDFs and DjVu keep the
--- engine search, page-bound anyway).
function XrayIndex.supported(document)
    return type(document) == "table" and document.getPageXPointer ~= nil
        and not (document.info and document.info.has_pages)
end

--- The layout this index entry belongs to, or nil while the layout is still
--- settling (KOReader re-rendering after a font or margin change: page
--- numbers are still moving).
function XrayIndex.stamp(ui)
    local doc = ui and ui.document
    if not XrayIndex.supported(doc) then return nil end
    if ui.rolling and ui.rolling.rendering_state ~= nil then return nil end
    if doc.isRerenderingDelayed then
        local ok, delayed = pcall(doc.isRerenderingDelayed, doc)
        if ok and delayed then return nil end
    end
    local ok, hash = pcall(doc.getDocumentRenderingHash, doc, true)
    if not ok or not hash or hash == 0 then return nil end
    local pages = doc.info and doc.info.number_of_pages
    if not pages or pages < 1 then return nil end
    local size = doc.file and lfs.attributes(doc.file, "size") or 0
    return string.format("%s:%s:%s", tostring(hash), tostring(pages), tostring(size))
end

function XrayIndex.path(file)
    if type(file) ~= "string" or file == "" or file:match("^__") then return nil end
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or not DocSettings then return nil end
    local ok_dir, dir = pcall(DocSettings.getSidecarDir, DocSettings, file)
    if not ok_dir or type(dir) ~= "string" or dir == "" then return nil end
    return dir .. "/" .. XrayIndex.FILE
end

--- The book's index table, or nil when it has none (memoized; this module is
--- the only writer).
function XrayIndex.load(file)
    local path = XrayIndex.path(file)
    if not path then return nil end
    local hit = loaded[path]
    if hit then return hit.data or nil end
    local data = false
    if lfs.attributes(path, "mode") == "file"
        or require("koassistant_storage_registry").migrateSidecarFile(file, path, XrayIndex.FILE) then
        local fn = loadfile(path)
        if fn then
            -- Data only: no globals (setfenv is LuaJIT/5.1; the unit tests run 5.4)
            if setfenv then setfenv(fn, {}) end
            local ok, res = pcall(fn)
            if ok and type(res) == "table" and res.version == VERSION
                    and type(res.layouts) == "table" then
                data = res
            else
                logger.warn("KOAssistant XrayIndex: unreadable index file, starting over")
            end
        end
    end
    loaded[path] = { data = data }
    return data or nil
end

--- The stored layout for this stamp, or nil.
function XrayIndex.layout(file, stamp)
    if not stamp then return nil end
    local data = XrayIndex.load(file)
    if not data then return nil end
    for _i, l in ipairs(data.layouts) do
        if l.stamp == stamp and type(l.forms) == "table" then return l end
    end
    return nil
end

--- Forms of `forms` (array or set) the layout does not hold.
function XrayIndex.missing(layout, forms)
    local out = {}
    local held = layout and layout.forms or {}
    if forms[1] ~= nil then
        for _i, f in ipairs(forms) do
            if held[f] == nil then out[#out + 1] = f end
        end
    else
        for f in pairs(forms) do
            if held[f] == nil then out[#out + 1] = f end
        end
    end
    return out
end

local function serialize(data)
    local out = { "return {\n  version = ", tostring(data.version), ",\n  layouts = {\n" }
    for _i, l in ipairs(data.layouts) do
        out[#out + 1] = "    {\n      stamp = " .. string.format("%q", l.stamp) .. ",\n      forms = {\n"
        local keys = {}
        for k in pairs(l.forms) do keys[#keys + 1] = k end
        table.sort(keys)
        for _j, k in ipairs(keys) do
            out[#out + 1] = "        [" .. string.format("%q", k) .. "] = "
                .. string.format("%q", l.forms[k]) .. ",\n"
        end
        out[#out + 1] = "      },\n    },\n"
    end
    out[#out + 1] = "  },\n}\n"
    return table.concat(out)
end

--- Merge a pass's results into the stored layout for `stamp` (created when
--- new, moved to the front; the oldest beyond MAX_LAYOUTS drops) and write.
--- @return table|nil the stored layout
function XrayIndex.store(file, stamp, results)
    local path = XrayIndex.path(file)
    if not (path and stamp and type(results) == "table") then return nil end
    local data = XrayIndex.load(file) or { version = VERSION, layouts = {} }
    local target
    for i, l in ipairs(data.layouts) do
        if l.stamp == stamp then
            target = table.remove(data.layouts, i)
            break
        end
    end
    target = target or { stamp = stamp, forms = {} }
    for form, enc in pairs(results) do
        if type(form) == "string" and type(enc) == "string" then target.forms[form] = enc end
    end
    target._decoded = nil
    table.insert(data.layouts, 1, target)
    while #data.layouts > MAX_LAYOUTS do table.remove(data.layouts) end
    local dir = path:match("(.*)/")
    if dir and lfs.attributes(dir, "mode") ~= "directory" then
        pcall(function() require("util").makePath(dir) end)
    end
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then
        logger.warn("KOAssistant XrayIndex: cannot write", tmp)
        return nil
    end
    f:write(serialize(data))
    f:close()
    local ok, err = os.rename(tmp, path)
    if not ok then
        logger.warn("KOAssistant XrayIndex: cannot replace index file:", err)
        os.remove(tmp)
        return nil
    end
    loaded[path] = { data = data }
    return target
end

-- ── The pass ─────────────────────────────────────────────────────────────

-- ASCII forms get a key word (their longest) so a page is only searched for
-- them when that word is on it: one word set per page instead of one scan
-- per form. Worth it once there are many forms.
local KEYED_MIN_FORMS = 16

local function formKey(form)
    if form:find("[\128-\255]") then return nil end
    local best
    for w in form:gmatch("%w+") do
        if not best or #w > #best then best = w end
    end
    return best
end

--- One pass over pages [first, last]: each page's text, normalized once,
--- every form's occurrences recorded. Pure against the document (runs in the
--- background child, in a Trapper subprocess, or in process for a span).
--- @return table { [form] = encoded } for every requested form ("" = none)
function XrayIndex.scan(document, forms, first, last)
    local total = document.info and document.info.number_of_pages or 0
    first = math.max(1, first or 1)
    last = math.min(total, last or total)
    local keyed, unkeyed = {}, {}
    if #forms >= KEYED_MIN_FORMS then
        for _i, f in ipairs(forms) do
            local k = formKey(f)
            if k then keyed[#keyed + 1] = { f, k } else unkeyed[#unkeyed + 1] = f end
        end
    else
        unkeyed = forms
    end
    local enc, lastp = {}, {}
    local function record(f, p, spans)
        local offs = {}
        for k, sp in ipairs(spans) do offs[k] = sp[1] end
        local list = enc[f]
        if not list then
            list = {}
            enc[f] = list
        end
        list[#list + 1] = (p - (lastp[f] or 0)) .. ":" .. table.concat(offs, ".")
        lastp[f] = p
    end
    local xp = document:getPageXPointer(first)
    for p = first, last do
        local nxp
        if p < total then
            nxp = document:getPageXPointer(p + 1)
        else
            nxp = require("koassistant_context_extractor").documentEndXPointer(document, total)
        end
        local text = (xp and nxp) and document:getTextFromXPointers(xp, nxp) or ""
        xp = nxp
        if text ~= "" then
            local norm = XrayParser.matchNormalize(text)
            if #keyed > 0 then
                local words = {}
                for w in norm:gmatch("%w+") do words[w] = true end
                for _i, kf in ipairs(keyed) do
                    if words[kf[2]] then
                        local spans = XrayParser._collectMatchSpans(norm, kf[1])
                        if #spans > 0 then record(kf[1], p, spans) end
                    end
                end
            end
            for _i, f in ipairs(unkeyed) do
                local spans = XrayParser._collectMatchSpans(norm, f)
                if #spans > 0 then record(f, p, spans) end
            end
        end
    end
    local out = {}
    for _i, f in ipairs(forms) do
        out[f] = enc[f] and table.concat(enc[f], ",") or ""
    end
    return out
end

-- ── Queries ──────────────────────────────────────────────────────────────

--- A form's stored occurrences: { pages = ascending, offs = { [page] = {...} } }
--- (memoized on the layout), or nil when the form is not indexed.
function XrayIndex.decode(layout, form)
    local memo = layout._decoded
    if not memo then
        memo = {}
        layout._decoded = memo
    end
    local hit = memo[form]
    if hit then return hit end
    local enc = layout.forms[form]
    if type(enc) ~= "string" then return nil end
    local pages, offs = {}, {}
    local page = 0
    for d, list in enc:gmatch("(%d+):([%d%.]+)") do
        page = page + tonumber(d)
        pages[#pages + 1] = page
        local o = {}
        for n in list:gmatch("%d+") do o[#o + 1] = tonumber(n) end
        offs[page] = o
    end
    hit = { pages = pages, offs = offs }
    memo[form] = hit
    return hit
end

--- Does the layout hold every form of this entity (and its containing forms)?
function XrayIndex.covers(layout, set, handles)
    if not (layout and set) then return false end
    for _i, f in ipairs(set.all) do
        if layout.forms[f] == nil then return false end
    end
    for _i, h in ipairs(handles or {}) do
        if layout.forms[h] == nil then return false end
    end
    return true
end

-- Occurrence count of one entity on one page from stored offsets: the union
-- and containment rule of XrayParser.occurrencesIn
local function countOnPage(layout, set, handles, p)
    local spans = {}
    for _i, f in ipairs(set.all) do
        local d = XrayIndex.decode(layout, f)
        local list = d and d.offs[p]
        if list then
            for _k, o in ipairs(list) do spans[#spans + 1] = { o, o + #f - 1, f } end
        end
    end
    if #spans == 0 then return 0 end
    if handles and #handles > 0 then
        local ex = {}
        for _i, h in ipairs(handles) do
            local d = XrayIndex.decode(layout, h)
            local list = d and d.offs[p]
            if list then
                for _k, o in ipairs(list) do ex[#ex + 1] = { o, o + #h - 1 } end
            end
        end
        if #ex > 0 then
            local kept = {}
            for _i, sp in ipairs(spans) do
                local inside = false
                for _k, x in ipairs(ex) do
                    if sp[1] >= x[1] and sp[2] <= x[2] then
                        inside = true
                        break
                    end
                end
                if not inside then kept[#kept + 1] = sp end
            end
            spans = kept
        end
    end
    return #XrayParser.mergeSpans(spans)
end

--- One entity's occurrences per page within [first, last] (both optional).
--- @return table|nil { [page] = count } (nil: a form is not indexed), number total
function XrayIndex.entityPages(layout, set, handles, first, last)
    if not XrayIndex.covers(layout, set, handles) then return nil, 0 end
    local candidates = {}
    for _i, f in ipairs(set.all) do
        for _k, p in ipairs(XrayIndex.decode(layout, f).pages) do
            if (not first or p >= first) and (not last or p <= last) then
                candidates[p] = true
            end
        end
    end
    local counts, total = {}, 0
    for p in pairs(candidates) do
        local n = countOnPage(layout, set, handles, p)
        if n > 0 then
            counts[p] = n
            total = total + n
        end
    end
    return counts, total
end

--- The entity's nearest page before `before` with an occurrence: a page
--- number, nil when there is none, false when a form is not indexed.
function XrayIndex.prevPage(layout, set, handles, before)
    if not XrayIndex.covers(layout, set, handles) then return false end
    local lists, ptr = {}, {}
    for i, f in ipairs(set.all) do
        local pages = XrayIndex.decode(layout, f).pages
        lists[i] = pages
        local lo, hi, idx = 1, #pages, 0
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            if pages[mid] < before then
                idx = mid
                lo = mid + 1
            else
                hi = mid - 1
            end
        end
        ptr[i] = idx
    end
    while true do
        local best
        for i, pages in ipairs(lists) do
            local k = ptr[i]
            if k > 0 and (not best or pages[k] > best) then best = pages[k] end
        end
        if not best then return nil end
        if countOnPage(layout, set, handles, best) > 0 then return best end
        for i, pages in ipairs(lists) do
            while ptr[i] > 0 and pages[ptr[i]] >= best do ptr[i] = ptr[i] - 1 end
        end
    end
end

-- ── Background and foreground passes ────────────────────────────────────

local function notify(p)
    for _i, fn in ipairs(p and p.listeners or {}) do
        pcall(fn)
    end
end

local startPass -- forward

local function scheduleStart(delay)
    UIManager:unschedule(startPass)
    UIManager:scheduleIn(delay or START_DELAY_S, startPass)
end

--- Stop the background pass (the child is killed and reaped). The request
--- stays queued unless `drop` (book closed: the loaded index and its
--- decoded forms go too, they belong to that book).
function XrayIndex.stop(drop)
    UIManager:unschedule(startPass)
    if drop then
        pending = nil
        loaded = {}
    end
    local run = running
    running = nil
    if run then
        run.cancelled = true
        local ffiutil = require("ffi/util")
        pcall(ffiutil.terminateSubProcess, run.pid)
        local tries = 0
        local function reap()
            tries = tries + 1
            if not ffiutil.isSubProcessDone(run.pid) and tries < 20 then
                UIManager:scheduleIn(1, reap)
            end
        end
        reap()
    end
end

local function writeAll(fd, data)
    local ffi = require("ffi")
    local ptr = ffi.cast("const char*", data)
    local total, written = #data, 0
    while written < total do
        local n = tonumber(ffi.C.write(fd, ptr + written, total - written))
        if not n or n < 0 then
            if ffi.errno() ~= 4 then return end -- anything but EINTR
            n = 0
        end
        written = written + n
    end
end

startPass = function()
    local p = pending
    if not p then return end
    local ui = p.ui
    local doc = ui and ui.document
    if not doc or doc.file ~= p.file then
        pending = nil
        return
    end
    local stamp = XrayIndex.stamp(ui)
    if not stamp then
        -- KOReader is still re-rendering: try again once it settles
        scheduleStart(START_DELAY_S * 3)
        return
    end
    local missing = XrayIndex.missing(XrayIndex.layout(p.file, stamp), p.forms)
    if #missing == 0 then return end
    if running then
        if running.file == p.file and running.stamp == stamp then
            local covered = true
            for _i, f in ipairs(missing) do
                if not running.forms[f] then
                    covered = false
                    break
                end
            end
            if covered then return end
        end
        XrayIndex.stop()
    end
    local ok_util, ffiutil = pcall(require, "ffi/util")
    local ok_buf, buffer = pcall(require, "string.buffer")
    local ok_ffi, ffi = pcall(require, "ffi")
    if not (ok_util and ok_buf and ok_ffi and type(ffiutil.runInSubProcess) == "function") then
        return
    end
    pcall(require, "ffi/posix_h")
    local total = doc.info.number_of_pages
    local child = function(pid, fd)
        if not pid or not fd then return end
        local ok, res = pcall(XrayIndex.scan, doc, missing, 1, total)
        local payload = ok and { ok = true, forms = res } or { ok = false, err = tostring(res) }
        local enc_ok, encoded = pcall(buffer.encode, payload)
        if enc_ok then writeAll(fd, encoded) end
        ffi.C.close(fd)
        pcall(function() ffi.C._exit(0) end)
    end
    local ok_fork, pid, read_fd = pcall(ffiutil.runInSubProcess, child, true)
    if not ok_fork or not pid or not read_fd then
        logger.warn("KOAssistant XrayIndex: background pass could not start")
        return
    end
    local run = { file = p.file, stamp = stamp, forms = {}, pid = pid, started = os.time() }
    for _i, f in ipairs(missing) do run.forms[f] = true end
    running = run
    logger.dbg("KOAssistant XrayIndex: background pass for", #missing, "forms")
    local chunk_size = 65536
    local chunk = ffi.new("char[?]", chunk_size)
    local pointer = ffi.cast("void*", chunk)
    local parts = {}
    local function finish()
        ffi.C.close(read_fd)
        if run.cancelled then return end
        if running == run then running = nil end
        local ok_dec, payload = pcall(buffer.decode, table.concat(parts))
        if not ok_dec or type(payload) ~= "table" or not payload.ok or type(payload.forms) ~= "table" then
            logger.warn("KOAssistant XrayIndex: background pass failed:",
                type(payload) == "table" and payload.err or "no result")
            return
        end
        -- Only while the book and its layout are still the ones read
        local cur = pending and pending.ui and pending.ui.document
        if not (cur and cur.file == run.file and XrayIndex.stamp(pending.ui) == run.stamp) then return end
        XrayIndex.store(run.file, run.stamp, payload.forms)
        logger.dbg("KOAssistant XrayIndex: background pass stored", #missing, "forms in",
            os.time() - run.started, "s")
        notify(pending)
        -- Forms asked for while this pass ran
        scheduleStart(1)
    end
    local function poll()
        if run.cancelled then
            pcall(ffi.C.close, read_fd)
            return
        end
        while true do
            local available = ffiutil.getNonBlockingReadSize(read_fd) or 0
            if available > 0 then
                local bytes = tonumber(ffi.C.read(read_fd, pointer, chunk_size))
                if bytes and bytes > 0 then
                    parts[#parts + 1] = ffi.string(pointer, bytes)
                else
                    finish()
                    return
                end
            elseif ffiutil.isSubProcessDone(pid) then
                while true do
                    local bytes = tonumber(ffi.C.read(read_fd, pointer, chunk_size))
                    if not bytes or bytes <= 0 then break end
                    parts[#parts + 1] = ffi.string(pointer, bytes)
                end
                finish()
                return
            else
                UIManager:scheduleIn(POLL_S, poll)
                return
            end
        end
    end
    UIManager:scheduleIn(POLL_S, poll)
end

--- Ask for these forms at the open book's layout. The ones not stored yet are
--- found by ONE background pass (a forked child, niced below the reader: page
--- turns keep priority) a few seconds after the last request, every queued
--- form together. on_ready runs after each pass lands.
--- @param ui table ReaderUI
--- @param forms table array of normalized forms
--- @param on_ready function|nil
function XrayIndex.request(ui, forms, on_ready)
    local doc = ui and ui.document
    if not XrayIndex.supported(doc) or not doc.file then return end
    if not (pending and pending.file == doc.file) then
        pending = { file = doc.file, ui = ui, forms = {}, listeners = {} }
    end
    pending.ui = ui
    for _i, f in ipairs(forms or {}) do pending.forms[f] = true end
    if on_ready then
        local known = false
        for _i, fn in ipairs(pending.listeners) do
            if fn == on_ready then known = true end
        end
        if not known then table.insert(pending.listeners, on_ready) end
    end
    scheduleStart()
end

--- Is a background pass for this book running now?
function XrayIndex.busy(file)
    return running ~= nil and running.file == file
end

--- The stored layout when it holds every form, or nil. Also queues any
--- missing form for the background pass.
function XrayIndex.ready(ui, forms)
    local doc = ui and ui.document
    if not (XrayIndex.supported(doc) and doc.file) then return nil end
    local layout = XrayIndex.layout(doc.file, XrayIndex.stamp(ui))
    if layout and #XrayIndex.missing(layout, forms) == 0 then return layout end
    XrayIndex.request(ui, forms)
    return nil
end

--- Find these forms now (Chapter Appearances, Mentions and their mention
--- lists when the stored index is not ready). A span (a section's own
--- pages) is read on its own and NOT stored (`layout.span` says which
--- pages it covers): in process up to IN_PROCESS_PAGES, else in a
--- subprocess with a tap-to-cancel message; the whole book keeps coming in
--- the background. Without a span the whole book is read in a subprocess
--- with a tap-to-cancel message and stored; a background pass for this
--- book stops first and its forms join this one. Must run inside
--- Trapper:wrap.
--- @param opts table|nil { first, last } span; nil = whole book
--- @return table|nil layout, nil when cancelled or the layout is settling
function XrayIndex.buildNow(ui, forms, opts)
    local doc = ui and ui.document
    if not (XrayIndex.supported(doc) and doc.file) then return nil end
    local stamp = XrayIndex.stamp(ui)
    if not stamp then return nil end
    local file = doc.file
    local total = doc.info.number_of_pages
    local stored = XrayIndex.layout(file, stamp)
    local span = opts and opts.first and opts.last
        and { math.max(1, opts.first), math.min(total, opts.last) } or nil
    if span then
        -- A section's own pages only (the whole book follows in the
        -- background): in process when short, else a subprocess (tap to cancel)
        if #XrayIndex.missing(stored, forms) == 0 then return stored end
        if span[2] - span[1] + 1 <= XrayIndex.IN_PROCESS_PAGES then
            return { stamp = stamp, forms = XrayIndex.scan(doc, forms, span[1], span[2]), span = span }
        end
        local Trapper = require("ui/trapper")
        local InfoMessage = require("ui/widget/infomessage")
        local info = InfoMessage:new{ text = _("Finding the X-Ray names in this section… (tap to cancel)") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local completed, res = Trapper:dismissableRunInSubprocess(function()
            return XrayIndex.scan(doc, forms, span[1], span[2])
        end, info)
        if not completed then return nil end
        UIManager:close(info)
        if type(res) ~= "table" then return nil end
        return { stamp = stamp, forms = res, span = span }
    end
    local want = {}
    for _i, f in ipairs(forms) do want[f] = true end
    if pending and pending.file == file then
        for f in pairs(pending.forms) do want[f] = true end
    end
    local missing = XrayIndex.missing(stored, want)
    if #missing == 0 then return stored end
    if running and running.file == file then XrayIndex.stop() end
    local Trapper = require("ui/trapper")
    local InfoMessage = require("ui/widget/infomessage")
    local info = InfoMessage:new{ text = _("Finding the X-Ray names in the book… (tap to cancel)") }
    UIManager:show(info)
    UIManager:forceRePaint()
    local started = os.time()
    local completed, res = Trapper:dismissableRunInSubprocess(function()
        return XrayIndex.scan(doc, missing, 1, total)
    end, info)
    if not completed then
        -- Cancelled: the background pass picks the forms up again later
        if pending and pending.file == file then scheduleStart(START_DELAY_S * 6) end
        return nil
    end
    UIManager:close(info)
    if type(res) ~= "table" then
        logger.warn("KOAssistant XrayIndex: name search process returned no result")
        return nil
    end
    local layout = XrayIndex.store(file, stamp, res)
    logger.dbg("KOAssistant XrayIndex: foreground pass stored", #missing, "forms in",
        os.time() - started, "s")
    if pending and pending.file == file then notify(pending) end
    return layout
end

-- ── Page words (the marks and the mention jump) ─────────────────────────

-- "<node path>.<char offset>" → path, offset (nil for element xpointers)
local function splitXPointer(xp)
    local path, off = xp:match("^(.*)%.(%d+)$")
    if path then return path, tonumber(off) end
    return nil
end

-- Byte position after `n` characters of UTF-8 `s` from byte `b`, and how
-- many characters were left when the text ran out
local function advanceChars(s, b, n)
    local len = #s
    while n > 0 and b <= len do
        local c = s:byte(b)
        if c < 0x80 then b = b + 1
        elseif c < 0xE0 then b = b + 2
        elseif c < 0xF0 then b = b + 3
        else b = b + 4 end
        n = n - 1
    end
    return b, n
end

--- The words of pages [first, last] with their start xpointers, plus
--- `margin` words either side (a name broken across the page edge still
--- matches; those words' boxes fall off the page), normalized as they come:
--- each piece's text is the word AND the separator after it, as the book
--- has it (none between CJK characters, an apostrophe inside "friend’s"), so
--- `norm` is the run's text through the one matcher and `range` says where
--- each piece sits in it.
--- Cost is about one crengine call per word, and every call re-resolves its
--- xpointer from the document root (tens of microseconds on a desktop late
--- in a book of a thousand files). So the walk steps from word start to word
--- start (from a word's END the next start skips every other CJK character,
--- each is a word there), cuts each piece from ONE read of the run's text by
--- the character offsets the xpointers carry, re-anchors on the run's text
--- where it crosses into another text node (the run's text puts line breaks
--- between blocks), and stops `margin` words after `stop_norm` bytes of
--- normalized text when the caller knows where its last name ends. Word ends
--- are fetched only for the words a name ends on (wordEnd).
--- @return table|nil pieces { ws, text, inside, range }, string norm
function XrayIndex.pageWords(document, first, last, margin, stop_norm)
    return XrayIndex.walkRun(document, XrayIndex.pageRun(document, first, last, margin), stop_norm)
end

--- The run pageWords walks, read once: from `margin` words before page
--- `first` to the start of the page after `last` (`text` is empty on the
--- book's last page, which is read word by word). Callers check the text
--- for names before paying for the walk.
--- @return table|nil { start, range_s, range_e, text, inside_from, margin }
function XrayIndex.pageRun(document, first, last, margin)
    local raw = document._document or document
    local total = document.info and document.info.number_of_pages or 0
    if total < 1 then return nil end
    margin = margin or 0
    local range_s = document:getPageXPointer(first)
    if not range_s then return nil end
    local range_e = last < total and document:getPageXPointer(last + 1) or nil
    -- Back up to the page's first word (the walk's next-start from the page
    -- start would skip it), then the margin
    local start = range_s
    for _i = 0, margin do
        local p = raw:getPrevVisibleWordStart(start)
        if not p or p == start then break end
        start = p
    end
    local text, inside_from = "", 1
    if range_e then
        text = raw:getTextFromXPointers(start, range_e, false, false) or ""
        inside_from = #(raw:getTextFromXPointers(start, range_s, false, false) or "") + 1
    end
    return { start = start, range_s = range_s, range_e = range_e, text = text,
        inside_from = inside_from, margin = margin }
end

--- Walk a pageRun (see pageWords).
--- @return table|nil pieces, string norm
function XrayIndex.walkRun(document, run, stop_norm)
    if not run then return nil end
    local raw = document._document or document
    local start, range_s, range_e = run.start, run.range_s, run.range_e
    local text, inside_from, margin = run.text, run.inside_from, run.margin
    local tlen = #text
    local builder = XrayParser.newPieceNormalizer()
    local pieces = {}
    local cursor = 1
    local cur = start
    local cur_path, cur_off = splitXPointer(cur)
    local past, guard = 0, 0
    local function readChunk(a, b)
        return raw:getTextFromXPointers(a, b, false, false) or ""
    end
    while cur and guard < 8000 do
        guard = guard + 1
        -- A word never starts with whitespace: a line break the run's text
        -- puts between blocks, or a space a range read trimmed, belongs to
        -- the piece before
        local ws_end = cursor
        while ws_end <= tlen do
            local c = text:byte(ws_end)
            if c ~= 32 and c ~= 10 and c ~= 13 and c ~= 9 then break end
            ws_end = ws_end + 1
        end
        if ws_end > cursor and #pieces > 0 then
            local prev = pieces[#pieces]
            prev.text = prev.text .. text:sub(cursor, ws_end - 1)
            cursor = ws_end
        end
        local nxt = raw:getNextVisibleWordStart(cur)
        if nxt == cur then nxt = nil end
        local nxt_path, nxt_off
        if nxt then nxt_path, nxt_off = splitXPointer(nxt) end
        local chunk
        if nxt and cursor <= tlen then
            local stop, short
            if cur_path and nxt_path == cur_path and nxt_off >= cur_off then
                -- Same text node: the xpointer offsets count characters of the run
                local after, left = advanceChars(text, cursor, nxt_off - cur_off)
                stop, short = after - 1, left > 0
            else
                -- Into another text node: re-anchor on the run's text
                stop = #readChunk(start, nxt)
            end
            if short or stop > tlen then
                -- The word runs past the page end (hyphenated across it)
                chunk = readChunk(cur, nxt)
            else
                chunk = text:sub(cursor, stop)
            end
        elseif nxt then
            -- Margin words after the page: read one by one
            chunk = readChunk(cur, nxt)
        else
            local we = raw:getNextVisibleWordEnd(cur)
            chunk = we and readChunk(cur, we) or ""
        end
        local inside
        if range_e then
            inside = cursor <= tlen and cursor + #chunk > inside_from
        else
            inside = raw:compareXPointers(range_s, cur) ~= -1
        end
        pieces[#pieces + 1] = { ws = cur, text = chunk, inside = inside }
        cursor = cursor + #chunk
        -- Normalize the piece before this one: its text is final now (the
        -- whitespace hand-back only ever grows the latest piece)
        if #pieces >= 2 then
            local pp = pieces[#pieces - 1]
            pp.range = builder.add(pp.text)
        end
        if (range_e and cursor > tlen) or (stop_norm and builder.len > stop_norm) then
            past = past + 1
            if past > margin then break end
        end
        if not nxt then break end
        cur, cur_path, cur_off = nxt, nxt_path, nxt_off
    end
    if #pieces > 0 then
        local lp = pieces[#pieces]
        lp.range = builder.add(lp.text)
    end
    return pieces, builder.result()
end

--- End xpointer of the word a piece starts (one call; only for the last
--- word of a name being marked or jumped to).
function XrayIndex.wordEnd(document, piece)
    local raw = document._document or document
    return raw:getNextVisibleWordEnd(piece.ws)
end

return XrayIndex
