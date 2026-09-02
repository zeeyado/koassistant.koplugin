--[[--
Book groups (xray_ecosystem_plan.md item 46, ref #90).

A group is a named list of documents. By default it is ORDERED — the order is
the reading/spoiler order and the single ordering truth for every consumer:
merge suggestions (earlier feeds later), prev/next artifact navigation, and
the future series X-Ray ("build through volume N").

An UNORDERED group (`ordered = false`, round 27 — maintainer: "a group that
isn't forced to be a series") is the same object with the sequence semantics
switched off: no predecessors, so no carry seed, no pre-create fold ask, no
series chain, no "comes LATER" direction warning. Everything else — shared
navigation, per-member merges, the group as a library-chat launch surface —
is identical. `predecessorsOf` is the ONE chokepoint the sequence features
read, so the gate lives there rather than in each caller.

Storage: settings_dir/koassistant_book_groups.lua via LuaSettings —
{ version = 1, next_id = N, groups = { { id, name, ordered, books = {…} } } }.
`ordered` is absent on every pre-round-27 group and nil means TRUE — existing
groups keep series behavior untouched.
A settings-dir FILE (not a G_reader_settings key) because groups are
user-authored data the backup manager must cover; global keys are
rebuildable-index territory. Registered in koassistant_storage_registry.lua.

Path identity: file paths, re-keyed on MOVE by the DocSettings.updateLocation
patch (main.lua). COPY does not join groups (a duplicate file is not a series
member); DELETE keeps the entry — missing files show "(missing)" and are
removed manually, never auto-pruned (a book on a removed SD card must not
fall out of its series). Index rebuild/prune must NOT touch groups.

Pure-loadable: UI-free; disk access goes through LuaSettings lazily.
]]

local logger = require("koassistant_logger")

local BookGroups = {}

local settings  -- lazy LuaSettings handle

local function store()
    if not settings then
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/koassistant_book_groups.lua")
    end
    return settings
end

--- Test seam: inject a fake LuaSettings-like handle (readSetting/saveSetting/flush).
function BookGroups._setStoreForTests(s)
    settings = s
end

local function load()
    local data = store():readSetting("book_groups")
    if type(data) ~= "table" or type(data.groups) ~= "table" then
        data = { version = 1, next_id = 1, groups = {} }
    end
    data.next_id = tonumber(data.next_id) or 1
    return data
end

local function save(data)
    store():saveSetting("book_groups", data)
    store():flush()
end

--- All groups, in creation order. Returns the live stored array — treat as
--- read-only; mutate through the API below.
--- @return table Array of { id, name, books }
function BookGroups.all()
    return load().groups
end

function BookGroups.byId(id)
    for _idx, group in ipairs(load().groups) do
        if group.id == id then return group end
    end
    return nil
end

--- @return table The created group
function BookGroups.create(name)
    local data = load()
    local group = {
        id = "g" .. data.next_id,
        name = (type(name) == "string" and name ~= "") and name or "?",
        books = {},
    }
    data.next_id = data.next_id + 1
    data.groups[#data.groups + 1] = group
    save(data)
    return group
end

function BookGroups.rename(id, name)
    if type(name) ~= "string" or name == "" then return false end
    local data = load()
    for _idx, group in ipairs(data.groups) do
        if group.id == id then
            group.name = name
            save(data)
            return true
        end
    end
    return false
end

-- Group KINDS (round 30). Two independent capabilities are in play — is there
-- an ORDER (predecessors, spoiler clamp, chain folds, carry seed) and is
-- cross-book KNOWLEDGE SHARING wanted (fold offers, group-level artifacts) —
-- and only three of the four combinations are useful, so this is one 3-way
-- choice rather than two switches:
--   series  = order + sharing   (the default, and every pre-existing group)
--   project = sharing, no order (siblings on a shared subject: fan-in folds,
--             no "earlier feeds later", no spoiler direction)
--   plain   = neither           (navigation and manual per-book merges only)
BookGroups.KIND_SERIES = "series"
BookGroups.KIND_PROJECT = "project"
BookGroups.KIND_PLAIN = "plain"

local VALID_KINDS = {
    [BookGroups.KIND_SERIES] = true,
    [BookGroups.KIND_PROJECT] = true,
    [BookGroups.KIND_PLAIN] = true,
}

--- This group's kind, resolved for groups written before the field existed.
--- Absent kind + absent `ordered` = SERIES (what every group has always been).
--- Absent kind + `ordered = false` = PLAIN: round 27's switch turned the
--- sequence features off and granted nothing in return, so it must NOT silently
--- become a project and start offering folds it never offered.
--- @param group table|nil
--- @return string kind
function BookGroups.kindOf(group)
    if not group then return BookGroups.KIND_SERIES end
    if VALID_KINDS[group.kind] then return group.kind end
    if group.ordered == false then return BookGroups.KIND_PLAIN end
    return BookGroups.KIND_SERIES
end

--- Does this group carry a reading ORDER? THE sequence chokepoint's input —
--- predecessorsOf reads it, so every sequence feature follows from here.
--- @param group table|nil
--- @return boolean
function BookGroups.isOrdered(group)
    return BookGroups.kindOf(group) == BookGroups.KIND_SERIES
end

--- Does this group share knowledge across its members (fold offers)?
--- @param group table|nil
--- @return boolean
function BookGroups.sharesKnowledge(group)
    local kind = BookGroups.kindOf(group)
    return kind == BookGroups.KIND_SERIES or kind == BookGroups.KIND_PROJECT
end

--- Change hook (S4, ref #90): main.lua registers a function(group_id) that
--- re-seeds the members' carried lists after a membership, order or kind
--- change (setOrdered delegates to setKind, so it is covered). Called AFTER
--- the store write; a failing hook never reaches the caller.
BookGroups.on_change = nil
local function notify(group_id)
    if type(BookGroups.on_change) == "function" then
        pcall(BookGroups.on_change, group_id)
    end
end

--- Set the group's kind (round 30).
--- @param id string
--- @param kind string One of KIND_SERIES / KIND_PROJECT / KIND_PLAIN
--- @return boolean changed
function BookGroups.setKind(id, kind)
    if not VALID_KINDS[kind] then return false end
    local data = load()
    for _idx, group in ipairs(data.groups) do
        if group.id == id then
            -- `kind` is the truth. `ordered` is written alongside purely as a
            -- back-compat mirror for anything (or any older build) still
            -- reading the round-27 field; kindOf prefers `kind`, so the two
            -- can never be consulted in the wrong order.
            group.kind = kind
            if kind == BookGroups.KIND_SERIES then
                group.ordered = nil
            else
                group.ordered = false
            end
            save(data); notify(id)
            return true
        end
    end
    return false
end

--- Round 27 API kept for callers that only care about the sequence switch:
--- true → series, false → plain. Delegates so there is ONE write path.
--- @return boolean changed
function BookGroups.setOrdered(id, ordered)
    return BookGroups.setKind(id,
        ordered == false and BookGroups.KIND_PLAIN or BookGroups.KIND_SERIES)
end

function BookGroups.remove(id)
    local data = load()
    for i, group in ipairs(data.groups) do
        if group.id == id then
            table.remove(data.groups, i)
            save(data)
            return true
        end
    end
    return false
end

local function indexOf(group, path)
    for i, p in ipairs(group.books or {}) do
        if p == path then return i end
    end
    return nil
end

--- Append a book (no duplicates; order = add order until reordered).
--- @return boolean added
function BookGroups.addBook(id, path)
    if type(path) ~= "string" or path == "" then return false end
    local data = load()
    for _idx, group in ipairs(data.groups) do
        if group.id == id then
            if indexOf(group, path) then return false end
            group.books[#group.books + 1] = path
            save(data); notify(id)
            return true
        end
    end
    return false
end

function BookGroups.removeBook(id, path)
    local data = load()
    for _idx, group in ipairs(data.groups) do
        if group.id == id then
            local i = indexOf(group, path)
            if not i then return false end
            table.remove(group.books, i)
            save(data); notify(id)
            return true
        end
    end
    return false
end

--- Move a book to an absolute 1-based position, clamped (kenken QoL, #90:
--- "Vol 15 definitely goes to rank 15" on 30-book groups).
--- @return boolean moved
function BookGroups.moveBookTo(id, path, pos)
    local n = tonumber(pos)
    if not n then return false end
    local data = load()
    for _idx, group in ipairs(data.groups) do
        if group.id == id then
            local i = indexOf(group, path)
            if not i then return false end
            local j = math.max(1, math.min(#group.books, math.floor(n)))
            if j == i then return false end
            table.remove(group.books, i)
            table.insert(group.books, j, path)
            save(data); notify(id)
            return true
        end
    end
    return false
end

--- Move a book by delta positions (-1 = up/earlier, 1 = down/later), clamped.
--- @return boolean moved
function BookGroups.moveBook(id, path, delta)
    local data = load()
    for _idx, group in ipairs(data.groups) do
        if group.id == id then
            local i = indexOf(group, path)
            if not i then return false end
            local j = math.max(1, math.min(#group.books, i + (tonumber(delta) or 0)))
            if j == i then return false end
            table.remove(group.books, i)
            table.insert(group.books, j, path)
            save(data); notify(id)
            return true
        end
    end
    return false
end

--- Every group containing the path, in creation order.
function BookGroups.groupsFor(path)
    local out = {}
    for _idx, group in ipairs(load().groups) do
        if indexOf(group, path) then out[#out + 1] = group end
    end
    return out
end

function BookGroups.positionOf(group, path)
    return indexOf(group, path)
end

--- Ordered neighbors of a book in its FIRST containing group (a book in
--- several groups navigates along the first one — documented limitation).
--- @return string|nil prev_path, string|nil next_path, table|nil group
function BookGroups.neighbors(path)
    local group = BookGroups.groupsFor(path)[1]
    if not group then return nil, nil, nil end
    local i = indexOf(group, path)
    return group.books[i - 1], group.books[i + 1], group
end

--- Paths BEFORE the book in its first containing group, in group order
--- (book 1 first) — the "fold in all earlier books" input.
--- THE sequence chokepoint (round 27): an unordered group has no "earlier",
--- so this returns nothing and every sequence feature downstream — the carry
--- seed, the pre-create fold ask, the series chain, the predecessor-gap note
--- — stands down without needing its own gate. The group is still returned
--- so callers can name it.
--- @return table paths, table|nil group
function BookGroups.predecessorsOf(path)
    local group = BookGroups.groupsFor(path)[1]
    if not group then return {}, nil end
    if not BookGroups.isOrdered(group) then return {}, group end
    local out = {}
    for _idx, p in ipairs(group.books) do
        if p == path then break end
        out[#out + 1] = p
    end
    return out, group
end

--- Books whose X-Rays may answer a lookup for this book, in rank order
--- (S4, ref #90): ordered group = earlier books nearest first, then — only
--- when `both_ways` (the current book is not under spoiler protection) —
--- later books nearest first; unordered knowledge-sharing group (project) =
--- every other member in list order; plain group = none. First containing
--- group, like neighbors/predecessorsOf.
--- @param path string
--- @param both_ways boolean|nil
--- @return table rows { { file, direction = "earlier"|"later"|nil }, ... }, table|nil group
function BookGroups.lookupBooksFor(path, both_ways)
    local group = BookGroups.groupsFor(path)[1]
    if not group then return {}, nil end
    local out = {}
    if BookGroups.isOrdered(group) then
        local i = indexOf(group, path)
        for j = i - 1, 1, -1 do
            out[#out + 1] = { file = group.books[j], direction = "earlier" }
        end
        if both_ways then
            for j = i + 1, #group.books do
                out[#out + 1] = { file = group.books[j], direction = "later" }
            end
        end
    elseif BookGroups.sharesKnowledge(group) then
        for _idx, p in ipairs(group.books) do
            if p ~= path then out[#out + 1] = { file = p } end
        end
    end
    return out, group
end

--- updateLocation hook (main.lua patch): MOVE re-keys memberships; COPY does
--- not join groups; DELETE keeps the entry (missing-file policy above).
function BookGroups.updateForMove(old_path, new_path, copy)
    if copy or not new_path or not old_path then return end
    local data = load()
    local changed = false
    for _idx, group in ipairs(data.groups) do
        local i = indexOf(group, old_path)
        if i then
            -- The new path may already be a member (odd overwrite-move): drop
            -- the old slot instead of duplicating
            if indexOf(group, new_path) then
                table.remove(group.books, i)
            else
                group.books[i] = new_path
            end
            changed = true
        end
    end
    if changed then
        save(data)
        logger.info("KOAssistant BookGroups: re-keyed moved book in groups")
    end
end

--- Does the file exist on disk? (Missing members stay listed, marked.)
function BookGroups.fileExists(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not lfs then return true end
    return lfs.attributes(path, "mode") == "file"
end

--- Display title for any group member: AI metadata override > doc_props >
--- filename. Same identity rule as the merge picker.
function BookGroups.displayTitle(path, ui)
    local title
    local ok, ds = pcall(function()
        return require("koassistant_doc_settings").resolve(path, ui)
    end)
    if ok and ds then
        local props = ds:readSetting("doc_props") or {}
        title = props.display_title or props.title
        local ok_ov, ov_title = pcall(function()
            return require("koassistant_book_settings").getMetadataOverride(ds)
        end)
        if ok_ov and ov_title ~= nil then title = ov_title end
    end
    if not title or title == "" then
        title = path:match("([^/]+)%.[^.]+$") or path:match("([^/]+)$") or path
    end
    return title
end

--- Members as {title, authors, file} rows for the library machinery
--- (item 48(a) launch surface). Existing files only; identity rule = AI
--- metadata override > doc_props > filename, same as the merge picker.
function BookGroups.booksInfoFor(group, ui)
    local out = {}
    for _idx, path in ipairs((group and group.books) or {}) do
        if BookGroups.fileExists(path) then
            local title, author
            local ok, ds = pcall(function()
                return require("koassistant_doc_settings").resolve(path, ui)
            end)
            if ok and ds then
                local props = ds:readSetting("doc_props") or {}
                title = props.display_title or props.title
                author = props.authors
                if type(author) == "string" and author:find("\n") then
                    author = author:gsub("\n", ", ")
                end
                local ov_t, ov_a = require("koassistant_book_settings").getMetadataOverride(ds)
                if ov_t ~= nil then title = ov_t end
                if ov_a ~= nil then author = ov_a end
            end
            if not title or title == "" then
                title = path:match("([^/]+)%.[^.]+$") or path:match("([^/]+)$") or path
            end
            out[#out + 1] = { title = title, authors = author or "", file = path }
        end
    end
    return out
end

--- Series-tag normalization for matching (P5 item 7): series lines in book
--- metadata vary in case and whitespace between files of one series, so the
--- compare folds both. ASCII case fold only (:lower()) — a non-ASCII series
--- name degrades to an exact-bytes compare, which is still correct when the
--- tag was written by the same tool across the set (the normal case).
--- @param s any
--- @return string|nil Normalized tag, nil for empty/non-string
function BookGroups.normalizeSeries(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    if s == "" then return nil end
    return s:lower()
end

--- Sort { path=, idx= } entries into series order: numeric series_index
--- first (ascending, decimals kept — ".5" side-volumes are real), entries
--- without an index after them in natural filename order (the picker's
--- pathOrderLess, so "vol 2" stays before "vol 10"). Pure; returns a new
--- array, input untouched.
--- @param entries table Array of { path = string, idx = number|string|nil }
--- @return table Sorted copy
function BookGroups.orderBySeriesIndex(entries)
    local out = {}
    for i, e in ipairs(entries or {}) do out[i] = e end
    local less = require("koassistant_book_picker").pathOrderLess
    table.sort(out, function(a, b)
        local ia, ib = tonumber(a.idx), tonumber(b.idx)
        if ia and ib and ia ~= ib then return ia < ib end
        if ia and not ib then return true end
        if ib and not ia then return false end
        return less(a.path, b.path)
    end)
    return out
end

--- Order merge-picker candidates by group relation to the current book
--- (item 46 "earlier feeds later"): predecessors first, NEAREST predecessor
--- on top (book N-1, then N-2, …), then later group-mates in group order,
--- then everything else in the order given (caller pre-sorts alphabetically).
--- Annotates group-mates in place: group_name, group_pos, group_direction
--- ("before"/"after") — the confirm dialog's directional warning reads these.
--- UNORDERED group (round 27): mates still lead the list, in group order, but
--- carry NO group_pos and NO group_direction — there is no "book 3 of 5" and
--- no "comes LATER" to warn about, and the empty direction is what keeps the
--- series-chain row out of the picker.
--- Pure when `groups` is passed (tests); defaults to the stored groups.
--- @param candidates table Array of { file, ... } (mutated: annotations only)
--- @param current_path string The target book
--- @param groups table|nil Override for tests
--- @param group_id string|nil Order by THIS group (multi-group books pick a
---   lens in the merge flow); default = first group containing current_path
--- @return table New sorted array (same candidate tables)
function BookGroups.orderCandidates(candidates, current_path, groups, group_id)
    groups = groups or load().groups
    local group, cur_pos
    for _idx, g in ipairs(groups) do
        local i = indexOf(g, current_path)
        if i and (not group_id or g.id == group_id) then group, cur_pos = g, i break end
    end
    local ordered = BookGroups.isOrdered(group)
    local before, after, rest = {}, {}, {}
    for _idx, cand in ipairs(candidates or {}) do
        local pos = group and indexOf(group, cand.file)
        if pos then
            cand.group_name = group.name
            if ordered then
                cand.group_pos = pos
                cand.group_direction = pos < cur_pos and "before" or "after"
            else
                cand.group_pos = nil
                cand.group_direction = nil
                cand.group_order = pos  -- list order only, never shown
            end
            if ordered and pos < cur_pos then before[#before + 1] = cand
            else after[#after + 1] = cand end
        else
            rest[#rest + 1] = cand
        end
    end
    table.sort(before, function(a, b) return a.group_pos > b.group_pos end)
    table.sort(after, function(a, b)
        return (a.group_pos or a.group_order or 0) < (b.group_pos or b.group_order or 0)
    end)
    local out = {}
    for _idx, list in ipairs({ before, after, rest }) do
        for _idx2, cand in ipairs(list) do out[#out + 1] = cand end
    end
    return out
end

return BookGroups
