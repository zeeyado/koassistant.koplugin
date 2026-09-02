--[[--
Book groups manager UI (xray_ecosystem_plan.md item 46, ref #90).

Small ButtonDialog stack over koassistant_book_groups.lua:
- showManager: all groups → per-group screen; create.
- showGroup: ordered member list (tap a book for move/remove), add books via
  the existing multi-select BookPicker, rename, delete.
- showBookRow: the Book Settings entry — this book's memberships, join/create.

Entry points: main menu row (settings schema "book_groups"), Book Settings
row, and the cross-book merge picker footer.
]]

local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("koassistant_gettext")

local GroupsUI = {}

local function groups() return require("koassistant_book_groups") end

--- Display name for a group (A3): "?" is the store's unnamed placeholder
--- (create("") — auto-named on first add), and it leaked as a bare "?" on
--- every surface that read `group.name` raw. EVERY surface naming a group
--- must route through this. Accepts a group table or a raw name string
--- (orderCandidates annotations carry the raw name).
function GroupsUI.displayName(g)
    local name = (type(g) == "table") and g.name or g
    if type(name) == "string" and name ~= "" and name ~= "?" then return name end
    return _("(unnamed)")
end
local displayName = GroupsUI.displayName

--- Book Settings row value: "None", "Name", or "Name +2".
function GroupsUI.rowLabel(path)
    local list = groups().groupsFor(path)
    if #list == 0 then return _("None") end
    local label = displayName(list[1])
    if #list > 1 then label = label .. " +" .. (#list - 1) end
    return label
end

local function promptName(title, initial, on_done, on_cancel, popts)
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = initial or "",
        description = popts and popts.description or nil,
        buttons = {{
            { text = _("Cancel"), id = "close",
                callback = function()
                    UIManager:close(dialog)
                    if on_cancel then on_cancel() end
                end },
            { text = _("Save"), is_enter_default = true,
                callback = function()
                    local name = dialog:getInputText()
                    UIManager:close(dialog)
                    if name and name ~= "" then
                        on_done(name)
                    elseif popts and popts.allow_empty then
                        -- Kenken QoL (#90): CJK typing is painful — an empty
                        -- name is allowed and auto-filled from the first book
                        on_done("")
                    elseif on_cancel then
                        on_cancel()
                    end
                end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Short name for a group kind (round 30). Kept SHORT: three of these share
--- one row with a ●/○ marker each.
--- @param kind string
--- @return string
function GroupsUI.kindLabel(kind)
    local BookGroups = groups()
    if kind == BookGroups.KIND_PROJECT then return _("Project") end
    if kind == BookGroups.KIND_PLAIN then return _("Plain") end
    return _("Series")
end

--- What each kind actually DOES — the same sentence in the picker and under the
--- group title, so the choice is never a guess.
--- @param kind string
--- @return string
function GroupsUI.kindDescription(kind)
    local BookGroups = groups()
    if kind == BookGroups.KIND_PROJECT then
        return _("Books on a shared subject, in no particular order. You can fold the other members' X-Rays into whichever book you are reading; nothing is carried forward automatically and no book counts as earlier or later.")
    end
    if kind == BookGroups.KIND_PLAIN then
        return _("Just a list. The books share navigation, and you can still merge any two by hand, but nothing is suggested or carried across.")
    end
    return _("Order is the reading order — it drives merge suggestions, carried-over knowledge and previous/next navigation.")
end

-- Kind step at creation (A3): every new group used to be silently a SERIES,
-- so the next X-Ray create offered sequence folds on e.g. an author
-- collection — token-spending wrong offers. One 3-button step right after
-- the name; tap-outside keeps the series default (what every pre-existing
-- group is), and the group screen shown next carries the full sentence plus
-- the kind switch, so a mis-pick is visible and fixable in place.
local function promptKind(on_done)
    local ButtonDialog = require("ui/widget/buttondialog")
    local BookGroups = groups()
    local dialog
    local rows = {}
    for _idx, k in ipairs({ BookGroups.KIND_SERIES, BookGroups.KIND_PROJECT,
            BookGroups.KIND_PLAIN }) do
        local captured = k
        rows[#rows + 1] = {{
            text = GroupsUI.kindLabel(captured),
            callback = function()
                UIManager:close(dialog)
                on_done(captured)
            end,
        }}
    end
    dialog = ButtonDialog:new{
        title = _("What kind of group?") .. "\n"
            .. _("Series: reading order matters — knowledge carries forward.") .. "\n"
            .. _("Project: same subject, no order — fold X-Rays on demand.") .. "\n"
            .. _("Plain: just a list."),
        buttons = rows,
        tap_close_callback = function() on_done(BookGroups.KIND_SERIES) end,
    }
    UIManager:show(dialog)
end

-- Shared creation tail: kind step, then create — the kind is asked BEFORE
-- the store write so a dismissed step still completes as a plain series
-- create rather than leaving a half-configured group behind a closed dialog.
local function createWithKind(name, after)
    promptKind(function(kind)
        local BookGroups = groups()
        local group = BookGroups.create(name)
        if kind ~= BookGroups.KIND_SERIES then
            BookGroups.setKind(group.id, kind)
        end
        require("koassistant_logger").dbg("KOAssistant Groups: created",
            group.id, "kind=", tostring(kind))
        after(group)
    end)
end

-- P5 item 7 (Q5 gripe): series metadata → group. Detection reads the CHEAP
-- local chain only (sidecar doc_props, coverbrowser cache, custom metadata —
-- KOReader's own BookInfo:getDocProps with no_open_document); the scan behind
-- it passes allow_open so never-opened books get a metadata-only document
-- open, because the primary use case is a freshly copied series folder with
-- no sidecars at all. Local metadata compare throughout, no AI involved.
local function readSeriesProps(path, ui, allow_open)
    if not (path and ui and ui.bookinfo) then return nil end
    local ok, props = pcall(ui.bookinfo.getDocProps, ui.bookinfo, path, nil, not allow_open)
    if not ok or type(props) ~= "table" then return nil end
    -- A series typed into KOReader's Book information editor lives in the
    -- custom metadata file, which getDocProps only folds in through the
    -- cover browser's cache; overlay it here so an edited or hand-added
    -- series counts everywhere (the chat index's edited-title precedent)
    if type(ui.bookinfo.extendProps) == "function" then
        local ok2, ext = pcall(ui.bookinfo.extendProps, props, path)
        if ok2 and type(ext) == "table" then props = ext end
    end
    if type(props.series) ~= "string" or props.series == "" then return nil end
    return { series = props.series, idx = tonumber(props.series_index) }
end

-- The scan: match candidates by normalized series tag, offer the adds, then
-- sort the WHOLE group by series index. The full sort is safe by construction:
-- this flow only ever runs on the group the suggest just created, so no
-- hand-tuned order exists to destroy. The InfoMessage paints before the work
-- starts (scheduleIn) — metadata-only opens cost real time on e-ink.
local function runSeriesScan(group_id, seed_path, sp, candidates, source_label, opts)
    local BookGroups = groups()
    local InfoMessage = require("ui/widget/infomessage")
    local want = BookGroups.normalizeSeries(sp.series)
    local info = InfoMessage:new{
        text = T(_("Checking %1 book(s)…"), #candidates),
    }
    UIManager:show(info)
    local function done() GroupsUI.showGroup(group_id, opts) end
    UIManager:scheduleIn(0.1, function()
        local group = BookGroups.byId(group_id)
        local matches = {}
        for _idx, p in ipairs(candidates) do
            if not (group and BookGroups.positionOf(group, p)) then
                local cp = readSeriesProps(p, opts.ui, true)
                if cp and BookGroups.normalizeSeries(cp.series) == want then
                    matches[#matches + 1] = { path = p, idx = cp.idx }
                end
            end
        end
        UIManager:close(info)
        if #matches == 0 then
            UIManager:show(InfoMessage:new{
                text = T(_("No other books tagged with the series \"%1\" were found in %2."),
                    sp.series, source_label),
                timeout = 4,
            })
            done()
            return
        end
        local ButtonDialog = require("ui/widget/buttondialog")
        local ask
        ask = ButtonDialog:new{
            title = T(_("Found %1 book(s) tagged with the series \"%2\"."),
                #matches, sp.series),
            buttons = {
                {{ text = T(_("Add all (%1)"), #matches), callback = function()
                    UIManager:close(ask)
                    local added = 0
                    for _idx, m in ipairs(matches) do
                        if BookGroups.addBook(group_id, m.path) then added = added + 1 end
                    end
                    local idx_map = { [seed_path] = sp.idx }
                    for _idx, m in ipairs(matches) do idx_map[m.path] = m.idx end
                    local g = BookGroups.byId(group_id)
                    if g then
                        local entries = {}
                        for _idx, p in ipairs(g.books) do
                            entries[#entries + 1] = { path = p, idx = idx_map[p] }
                        end
                        local sorted = BookGroups.orderBySeriesIndex(entries)
                        for i, e in ipairs(sorted) do
                            BookGroups.moveBookTo(group_id, e.path, i)
                        end
                    end
                    UIManager:show(require("ui/widget/notification"):new{
                        text = T(_("Added %1 book(s)."), added),
                    })
                    done()
                end }},
                {{ text = _("Cancel"), callback = function()
                    UIManager:close(ask)
                    done()
                end }},
            },
        }
        UIManager:show(ask)
    end)
end

-- Source pick for the series scan (the veto's shape: "find matching series
-- in…" over folders or collections). Collections row only when any exist.
local function offerSeriesScan(group_id, seed_path, sp, opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local function done() GroupsUI.showGroup(group_id, opts) end
    local rows = {}
    rows[#rows + 1] = {{
        text = _("Look in a folder…"),
        callback = function()
            UIManager:close(dialog)
            local PathChooser = require("ui/widget/pathchooser")
            local Device = require("device")
            local DataStorage = require("datastorage")
            local picked = false
            UIManager:show(PathChooser:new{
                title = _("Select Folder"),
                path = G_reader_settings:readSetting("home_dir")
                    or Device.home_dir or DataStorage:getDataDir(),
                select_directory = true,
                select_file = false,
                onConfirm = function(folder)
                    picked = true
                    local BookPicker = require("koassistant_book_picker")
                    local paths, err = BookPicker.listFolderBooks(folder)
                    if not paths or #paths == 0 then
                        UIManager:show(require("ui/widget/infomessage"):new{
                            text = err or T(_("No books found in:\n%1"), folder),
                            timeout = 3,
                        })
                        done()
                        return
                    end
                    runSeriesScan(group_id, seed_path, sp, paths,
                        folder:match("([^/]+)/?$") or folder, opts)
                end,
                close_callback = function()
                    if not picked then done() end
                end,
            })
        end,
    }}
    local coll_ok, ReadCollection = pcall(require, "readcollection")
    local coll_names = {}
    if coll_ok and type(ReadCollection.coll) == "table" then
        for name in pairs(ReadCollection.coll) do coll_names[#coll_names + 1] = name end
        table.sort(coll_names)
    end
    if #coll_names > 0 then
        rows[#rows + 1] = {{
            text = _("Look in a collection…"),
            callback = function()
                UIManager:close(dialog)
                local coll_dialog
                local coll_rows = {}
                for _idx, name in ipairs(coll_names) do
                    local captured = name
                    local label = captured == ReadCollection.default_collection_name
                        and _("Favorites") or captured
                    local n = 0
                    for _f in pairs(ReadCollection.coll[captured] or {}) do n = n + 1 end
                    coll_rows[#coll_rows + 1] = {{
                        text = label .. " (" .. n .. ")",
                        align = "left",
                        callback = function()
                            UIManager:close(coll_dialog)
                            local paths = {}
                            for f in pairs(ReadCollection.coll[captured] or {}) do
                                paths[#paths + 1] = f
                            end
                            runSeriesScan(group_id, seed_path, sp, paths, label, opts)
                        end,
                    }}
                end
                coll_rows[#coll_rows + 1] = {{ text = _("Cancel"), callback = function()
                    UIManager:close(coll_dialog)
                    done()
                end }}
                coll_dialog = ButtonDialog:new{
                    title = _("Which collection?"),
                    buttons = coll_rows,
                }
                UIManager:show(coll_dialog)
            end,
        }}
    end
    rows[#rows + 1] = {{ text = _("Not now"), callback = function()
        UIManager:close(dialog)
        done()
    end }}
    dialog = ButtonDialog:new{
        title = T(_("Group \"%1\" created with this book.\nFind the rest of the series?\nBooks whose metadata carries the same series tag can be added automatically."),
            sp.series),
        buttons = rows,
        tap_close_callback = done,
    }
    UIManager:show(dialog)
end

-- The suggest row (nil when there is nothing to suggest): the book's own
-- metadata names a series → one tap creates the group after it. The KIND step
-- is skipped on purpose — a series tag already answered what promptKind would
-- ask (create() defaults to series). Suppressed once any group carries the
-- series' name: the join rows cover that case, a second suggest would only
-- breed duplicates. opts = what showGroup gets ({ plugin, ui, on_close });
-- host_close closes the dialog the row sits in.
local function seriesSuggestRow(path, host_close, opts)
    local sp = readSeriesProps(path, opts.ui, false)
    if not sp then return nil end
    local BookGroups = groups()
    local want = BookGroups.normalizeSeries(sp.series)
    for _idx, g in ipairs(BookGroups.all()) do
        if BookGroups.normalizeSeries(g.name) == want then return nil end
    end
    return {
        text = T(_("New group from series \"%1\"…"), sp.series),
        callback = function()
            host_close()
            local group = BookGroups.create(sp.series)
            BookGroups.addBook(group.id, path)
            offerSeriesScan(group.id, path, sp, opts)
        end,
    }
end

-- Fold target picker (A3 fan-in surfacing): a project group's fold needs ONE
-- receiving book — the member picked here launches the cross-book picker,
-- whose "Fold in the other books…" row is the fan-in.
local function showFoldTargetPicker(group_id, opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local BookGroups = groups()
    local group = BookGroups.byId(group_id)
    if not group then return end
    local ActionCache = require("koassistant_action_cache")
    local XrayParser = require("koassistant_xray_parser")
    local dialog
    local rows = {}
    local has_n = 0
    for _idx, path in ipairs(group.books) do
        local captured = path
        local title = BookGroups.displayTitle(captured, opts.ui)
        local ok, e = pcall(ActionCache.getXrayCache, captured)
        local has = ok and e and e.result and XrayParser.isJSON(e.result) and true or false
        if has then has_n = has_n + 1 end
        rows[#rows + 1] = {{
            text = has and title or (title .. " " .. _("(no X-Ray)")),
            align = "left",
            enabled = has,
            callback = function()
                UIManager:close(dialog)
                opts.plugin:_startCrossBookXrayFlow(captured)
            end,
        }}
    end
    if has_n == 0 then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("No book in this group has an X-Ray yet. Create one first."),
            timeout = 4,
        })
        GroupsUI.showGroup(group_id, opts)
        return
    end
    rows[#rows + 1] = {{ text = _("Cancel"), callback = function()
        UIManager:close(dialog)
        GroupsUI.showGroup(group_id, opts)
    end }}
    dialog = ButtonDialog:new{
        title = _("Fold the group's X-Rays into which book?") .. "\n"
            .. _("Knowledge flows INTO the book you pick — the others are not changed."),
        buttons = rows,
    }
    UIManager:show(dialog)
end

--- Self-refreshing member move dialog (kenken QoL, #90: 30-book reordering).
--- The arrow dialog PERSISTS across presses: each press moves the book,
--- refreshes the group list underneath, and re-shows this dialog with fresh
--- position and enabled state — press-press-press instead of
--- reopen-relocate-press. "Move to position…" jumps directly.
--- opts: same table showGroup received ({ plugin, ui, on_close }).
function GroupsUI.showMoveDialog(group_id, path, opts)
    require("koassistant_logger").dbg("KOAssistant Groups: move dialog", group_id, path)
    opts = opts or {}
    local ButtonDialog = require("ui/widget/buttondialog")
    local BookGroups = groups()
    local group = BookGroups.byId(group_id)
    local i = group and BookGroups.positionOf(group, path)
    if not i then return end
    local n = #group.books
    local title = BookGroups.displayTitle(path, opts.ui)
    local book_dialog
    local function refreshBoth()
        UIManager:close(book_dialog)
        if GroupsUI._group_dialog then UIManager:close(GroupsUI._group_dialog) end
        GroupsUI.showGroup(group_id, opts)
        GroupsUI.showMoveDialog(group_id, path, opts)
    end
    book_dialog = ButtonDialog:new{
        title = T(_("%1: position %2 of %3"), title, i, n),
        buttons = {
            {
                { text = "\u{2191}", enabled = i > 1, callback = function()
                    BookGroups.moveBook(group_id, path, -1)
                    refreshBoth()
                end },
                { text = "\u{2193}", enabled = i < n, callback = function()
                    BookGroups.moveBook(group_id, path, 1)
                    refreshBoth()
                end },
            },
            {{ text = _("Move to position…"), callback = function()
                UIManager:close(book_dialog)
                -- SpinWidget (kenken round 5): the KOReader number wheel —
                -- scroll to the slot (hold arrows jump by 5) or tap the value
                -- to type it; beats a bare input field on 30-book groups
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new{
                    title_text = T(_("Move \"%1\" to position"), title),
                    info_text = T(_("1-%1 (currently %2)"), n, i),
                    value = i,
                    value_min = 1,
                    value_max = n,
                    value_step = 1,
                    value_hold_step = 5,
                    ok_text = _("Move"),
                    ok_always_enabled = true,
                    callback = function(spin)
                        BookGroups.moveBookTo(group_id, path, spin.value)
                        if GroupsUI._group_dialog then UIManager:close(GroupsUI._group_dialog) end
                        GroupsUI.showGroup(group_id, opts)
                        GroupsUI.showMoveDialog(group_id, path, opts)
                    end,
                    cancel_callback = function()
                        GroupsUI.showMoveDialog(group_id, path, opts)
                    end,
                })
            end }},
            -- Groups double as navigation: jump to the member you want to
            -- work on (device request 2026-08-05)
            {{ text = _("Open this book"), enabled = BookGroups.fileExists(path),
                callback = function()
                    UIManager:close(book_dialog)
                    if GroupsUI._group_dialog then UIManager:close(GroupsUI._group_dialog) end
                    local ReaderUI = require("apps/reader/readerui")
                    if ReaderUI.instance and ReaderUI.instance.document
                        and ReaderUI.instance.document.file == path then
                        -- Already the open book — closing the dialogs reveals it;
                        -- showReader would reload the document from scratch
                        return
                    end
                    ReaderUI:showReader(path)
                end }},
            {{ text = _("Remove from group"), callback = function()
                UIManager:close(book_dialog)
                BookGroups.removeBook(group_id, path)
                if GroupsUI._group_dialog then UIManager:close(GroupsUI._group_dialog) end
                GroupsUI.showGroup(group_id, opts)
            end }},
            {{ text = _("Done"), callback = function()
                UIManager:close(book_dialog)
            end }},
        },
        shrink_unneeded_width = true,
    }
    UIManager:show(book_dialog)
end

--- Per-group screen. opts: { plugin, ui, on_close }
function GroupsUI.showGroup(group_id, opts)
    opts = opts or {}
    require("koassistant_logger").dbg("KOAssistant Groups: open group", group_id)
    local ButtonDialog = require("ui/widget/buttondialog")
    local BookGroups = groups()
    local group = BookGroups.byId(group_id)
    if not group then
        if opts.on_close then opts.on_close() end
        return
    end
    local dialog
    local function reopen()
        UIManager:close(dialog)
        GroupsUI.showGroup(group_id, opts)
    end
    GroupsUI._group_dialog = nil -- set below once constructed
    local rows = {}
    for i, path in ipairs(group.books) do
        local captured = path
        local title = BookGroups.displayTitle(captured, opts.ui)
        if not BookGroups.fileExists(captured) then
            title = title .. " " .. _("(missing)")
        end
        rows[#rows + 1] = {{
            text = i .. ". " .. title,
            align = "left",
            callback = function()
                GroupsUI.showMoveDialog(group_id, captured, opts)
            end,
        }}
    end
    if #group.books == 0 then
        rows[#rows + 1] = {{ text = _("No books yet — add some below."), enabled = false }}
    end
    -- Round 27 (device: "that whole group management window is a hot mess,
    -- such a long window, and why is the ordered series button randomly in the
    -- middle"): the book list is one row per book (it has to be — each row is
    -- a tap target), so the ACTIONS are what makes the window long. The
    -- ordered-series switch leads them, then the rest pair up two to a row.
    -- Round 30: the round-27 "Ordered series" checkbox became a three-way KIND,
    -- laid out as three buttons on the ONE row the checkbox used to occupy
    -- (maintainer). No extra dialog: the selected kind is marked here and the
    -- sentence under the group title changes with it, so the consequence of
    -- each choice is visible in place rather than behind a popup.
    local kind = BookGroups.kindOf(group)
    local kind_row = {}
    for _idx, k in ipairs({ BookGroups.KIND_SERIES, BookGroups.KIND_PROJECT,
            BookGroups.KIND_PLAIN }) do
        local captured = k
        kind_row[#kind_row + 1] = {
            text = (captured == kind and "● " or "○ ") .. GroupsUI.kindLabel(captured),
            callback = function()
                if captured ~= kind then BookGroups.setKind(group_id, captured) end
                reopen()
            end,
        }
    end
    rows[#rows + 1] = kind_row
    local actions = {}
    -- Round 29: the picker hands back a SET (hash keyed by path), so a plain
    -- pairs() loop added books in ARBITRARY order — for a 30-volume folder the
    -- reading order came out scrambled, which is the one thing a series group
    -- must get right. Adds now go in natural filename order (vol 2 before vol
    -- 10) and always APPEND, never splice: a hand-tuned order survives, and
    -- one move fixes a stray.
    -- Shared tail for every add path: name an unnamed group after its first
    -- book (kenken QoL #90 — CJK typing is painful in KOReader), report, reopen.
    local function addedDone(added)
        local g = BookGroups.byId(group_id)
        if g and (g.name == "?" or g.name == "") and g.books[1] then
            BookGroups.rename(group_id, BookGroups.displayTitle(g.books[1], opts.ui))
        end
        if added and added > 0 then
            UIManager:show(require("ui/widget/notification"):new{
                text = T(_("Added %1 book(s)."), added),
            })
        end
        GroupsUI.showGroup(group_id, opts)
    end
    local function addSelected(selected_files)
        local BookPicker = require("koassistant_book_picker")
        local added = 0
        for _idx, path in ipairs(BookPicker.orderedSelection(selected_files)) do
            if BookGroups.addBook(group_id, path) then added = added + 1 end
        end
        addedDone(added)
    end
    actions[#actions + 1] = {
        text = _("Add books…"),
        callback = function()
            UIManager:close(dialog)
            local BookPicker = require("koassistant_book_picker")
            BookPicker:show({
                on_confirm = function(selected_files) addSelected(selected_files) end,
                on_close = function() GroupsUI.showGroup(group_id, opts) end,
            })
        end,
    }
    -- Kenken (#90): "designate a folder as a group" without ticking every box.
    -- Round 29 second pass (maintainer: adding a library SCAN folder shows no
    -- list, why does this?): because a scan folder stores the FOLDER PATH and
    -- re-resolves it per request, while a group stores MEMBER PATHS and must
    -- enumerate. So enumerate silently: chooser → one confirm naming the count
    -- → done. No list. The confirm stays because this appends to a possibly
    -- hand-ordered group and a mis-tapped folder could add hundreds of books;
    -- curated picking is what "Add books…" above is for.
    -- Snapshot only: the group does not follow the folder afterwards (live
    -- binding is a separate, opt-in idea).
    actions[#actions + 1] = {
        text = _("Add all books in a folder…"),
        callback = function()
            UIManager:close(dialog)
            local PathChooser = require("ui/widget/pathchooser")
            local Device = require("device")
            local DataStorage = require("datastorage")
            local picked = false
            UIManager:show(PathChooser:new{
                title = _("Select Folder"),
                path = G_reader_settings:readSetting("home_dir")
                    or Device.home_dir or DataStorage:getDataDir(),
                select_directory = true,
                select_file = false,
                onConfirm = function(folder)
                    picked = true
                    local BookPicker = require("koassistant_book_picker")
                    local paths, err = BookPicker.listFolderBooks(folder)
                    if not paths or #paths == 0 then
                        UIManager:show(require("ui/widget/infomessage"):new{
                            text = err or T(_("No books found in:\n%1"), folder),
                            timeout = 3,
                        })
                        GroupsUI.showGroup(group_id, opts)
                        return
                    end
                    -- Three ways out, because "all of them" is the common case
                    -- but not the only one: add everything, open the picker with
                    -- everything already ticked so a few can be dropped, or back
                    -- out. The picker arm is why BookPicker keeps `select_all`.
                    local ButtonDialog = require("ui/widget/buttondialog")
                    local ask
                    ask = ButtonDialog:new{
                        title = T(_("Add %1 book(s) from \"%2\" to this group, in filename order?"),
                            #paths, folder:match("([^/]+)/?$") or folder),
                        buttons = {
                            {{ text = T(_("Add all (%1)"), #paths), callback = function()
                                UIManager:close(ask)
                                local added = 0
                                for _idx, path in ipairs(paths) do
                                    if BookGroups.addBook(group_id, path) then added = added + 1 end
                                end
                                addedDone(added)
                            end }},
                            {{ text = _("Choose which…"), callback = function()
                                UIManager:close(ask)
                                BookPicker:show({
                                    initial_source = folder,
                                    select_all = true,
                                    on_confirm = function(selected_files) addSelected(selected_files) end,
                                    on_close = function() GroupsUI.showGroup(group_id, opts) end,
                                })
                            end }},
                            {{ text = _("Cancel"), callback = function()
                                UIManager:close(ask)
                                GroupsUI.showGroup(group_id, opts)
                            end }},
                        },
                    }
                    UIManager:show(ask)
                end,
                close_callback = function()
                    if not picked then GroupsUI.showGroup(group_id, opts) end
                end,
            })
        end,
    }
    -- Item 48(a): the group as launch surface — library chat/actions with the
    -- members pre-selected (reading order kept; saved chats stamped with the group)
    if #group.books > 0 and opts.plugin and opts.plugin.openLibraryDialogForGroup then
        actions[#actions + 1] = {
            text = _("Library chat…"),
            callback = function()
                UIManager:close(dialog)
                opts.plugin:openLibraryDialogForGroup(group_id)
            end,
        }
    end
    -- A2/A3: the fold surface the kind picker promises, right on the group
    -- screen — series chain or project fan-in, via the cross-book picker (ONE
    -- flow owns consent, skip-done accounting and the confirms). Plain groups
    -- share nothing by design: no row (sharesKnowledge is the gate).
    if #group.books > 1 and opts.plugin and opts.plugin._startCrossBookXrayFlow
        and BookGroups.sharesKnowledge(group) then
        actions[#actions + 1] = {
            text = kind == BookGroups.KIND_PROJECT
                and _("Fold X-Rays into one book…") or _("Merge series X-Rays…"),
            callback = function()
                UIManager:close(dialog)
                if kind == BookGroups.KIND_PROJECT then
                    showFoldTargetPicker(group_id, opts)
                    return
                end
                -- Series: the chain runs oldest → newest, so launch the picker
                -- from the LAST member with an X-Ray — its "Fold in earlier
                -- books" row then covers the whole series
                local ActionCache = require("koassistant_action_cache")
                local XrayParser = require("koassistant_xray_parser")
                local target
                for _idx, p in ipairs(group.books) do
                    local ok, e = pcall(ActionCache.getXrayCache, p)
                    if ok and e and e.result and XrayParser.isJSON(e.result) then
                        target = p
                    end
                end
                if not target then
                    UIManager:show(require("ui/widget/infomessage"):new{
                        text = _("No book in this group has an X-Ray yet. Create one first."),
                        timeout = 4,
                    })
                    GroupsUI.showGroup(group_id, opts)
                    return
                end
                opts.plugin:_startCrossBookXrayFlow(target)
            end,
        }
    end
    actions[#actions + 1] = {
        text = _("Rename…"),
        callback = function()
            UIManager:close(dialog)
            -- Prefill skips the "?" placeholder — nothing worth editing in it
            promptName(_("Rename group"), group.name ~= "?" and group.name or "",
                function(name)
                    BookGroups.rename(group_id, name)
                    GroupsUI.showGroup(group_id, opts)
                end, function() GroupsUI.showGroup(group_id, opts) end)
        end,
    }
    actions[#actions + 1] = {
        text = _("Delete group…"),
        callback = function()
            local confirm
            confirm = ButtonDialog:new{
                title = T(_("Delete the group \"%1\"?\nBooks and their artifacts are not touched — only the grouping is removed."), displayName(group)),
                buttons = {
                    {{ text = _("Delete"), callback = function()
                        UIManager:close(confirm)
                        UIManager:close(dialog)
                        BookGroups.remove(group_id)
                        if opts.on_close then opts.on_close() end
                    end }},
                    {{ text = _("Cancel"), callback = function()
                        UIManager:close(confirm)
                    end }},
                },
            }
            UIManager:show(confirm)
        end,
    }
    for i = 1, #actions, 2 do
        local pair = { actions[i] }
        if actions[i + 1] then pair[2] = actions[i + 1] end
        rows[#rows + 1] = pair
    end
    rows[#rows + 1] = {{
        text = _("Back"),
        callback = function()
            UIManager:close(dialog)
            if opts.on_close then opts.on_close() end
        end,
    }}
    dialog = ButtonDialog:new{
        title = T(_("Group: %1"), displayName(group))
            .. "\n" .. GroupsUI.kindDescription(kind),
        buttons = rows,
    }
    -- The move dialog closes/reopens this list under itself (kenken QoL)
    GroupsUI._group_dialog = dialog
    UIManager:show(dialog)
end

--- Top-level manager. opts: { plugin, ui, on_close }
function GroupsUI.showManager(opts)
    opts = opts or {}
    local ButtonDialog = require("ui/widget/buttondialog")
    local BookGroups = groups()
    local dialog
    local rows = {}
    for _idx, group in ipairs(BookGroups.all()) do
        local captured = group
        rows[#rows + 1] = {{
            text = T(_("%1 (%2 books)"), displayName(captured), #captured.books),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                GroupsUI.showGroup(captured.id, {
                    plugin = opts.plugin, ui = opts.ui,
                    on_close = function() GroupsUI.showManager(opts) end,
                })
            end,
        }}
    end
    if #rows == 0 then
        rows[#rows + 1] = {{
            text = _("No groups yet. A group is an ordered set of books — a series, an author, a project."),
            enabled = false,
        }}
    end
    rows[#rows + 1] = {{
        text = _("New group…"),
        callback = function()
            UIManager:close(dialog)
            promptName(_("New group"), nil, function(name)
                createWithKind(name, function(group)
                    GroupsUI.showGroup(group.id, {
                        plugin = opts.plugin, ui = opts.ui,
                        on_close = function() GroupsUI.showManager(opts) end,
                    })
                end)
            end, function() GroupsUI.showManager(opts) end,
            { allow_empty = true,
              description = _("You can leave this empty: the group takes the name of the first book you add.") })
        end,
    }}
    -- P5 (maintainer gripe, Q5): folder → group in one flow — pick the folder,
    -- name the group (folder name prefilled), every book in it joins on create.
    -- Snapshot like "Add all books in a folder…" (the group does not follow the
    -- folder afterwards); curation is what the group screen's rows are for.
    rows[#rows + 1] = {{
        text = _("New group from folder…"),
        callback = function()
            UIManager:close(dialog)
            local PathChooser = require("ui/widget/pathchooser")
            local Device = require("device")
            local DataStorage = require("datastorage")
            local picked = false
            UIManager:show(PathChooser:new{
                title = _("Select Folder"),
                path = G_reader_settings:readSetting("home_dir")
                    or Device.home_dir or DataStorage:getDataDir(),
                select_directory = true,
                select_file = false,
                onConfirm = function(folder)
                    picked = true
                    local BookPicker = require("koassistant_book_picker")
                    local paths, err = BookPicker.listFolderBooks(folder)
                    if not paths or #paths == 0 then
                        UIManager:show(require("ui/widget/infomessage"):new{
                            text = err or T(_("No books found in:\n%1"), folder),
                            timeout = 3,
                        })
                        GroupsUI.showManager(opts)
                        return
                    end
                    promptName(_("New group"), folder:match("([^/]+)/?$") or "",
                        function(name)
                            createWithKind(name, function(group)
                                local added = 0
                                for _idx, p in ipairs(paths) do
                                    if groups().addBook(group.id, p) then added = added + 1 end
                                end
                                UIManager:show(require("ui/widget/notification"):new{
                                    text = T(_("Added %1 book(s), in filename order."), added),
                                })
                                GroupsUI.showGroup(group.id, {
                                    plugin = opts.plugin, ui = opts.ui,
                                    on_close = function() GroupsUI.showManager(opts) end,
                                })
                            end)
                        end, function() GroupsUI.showManager(opts) end,
                        { description = T(_("%1 book(s) from the folder will be added, in filename order."), #paths) })
                end,
                close_callback = function()
                    if not picked then GroupsUI.showManager(opts) end
                end,
            })
        end,
    }}
    -- Main-menu parity with Book Settings (kenken round 5): seed a group from
    -- the OPEN book right here — title prefilled, book added on create
    local open_file = opts.ui and opts.ui.document and opts.ui.document.file
    if open_file then
        rows[#rows + 1] = {{
            text = _("New group with this book…"),
            callback = function()
                UIManager:close(dialog)
                promptName(_("New group"), BookGroups.displayTitle(open_file, opts.ui), function(name)
                    createWithKind(name, function(group)
                        groups().addBook(group.id, open_file)
                        GroupsUI.showGroup(group.id, {
                            plugin = opts.plugin, ui = opts.ui,
                            on_close = function() GroupsUI.showManager(opts) end,
                        })
                    end)
                end, function() GroupsUI.showManager(opts) end)
            end,
        }}
        -- P5 item 7: the open book's series tag, one tap to a group named
        -- after it (then the find-the-rest scan)
        local series_row = seriesSuggestRow(open_file,
            function() UIManager:close(dialog) end,
            { plugin = opts.plugin, ui = opts.ui,
              on_close = function() GroupsUI.showManager(opts) end })
        if series_row then rows[#rows + 1] = { series_row } end
    end
    rows[#rows + 1] = {{
        text = _("Close"),
        callback = function()
            UIManager:close(dialog)
            if opts.on_close then opts.on_close() end
        end,
    }}
    dialog = ButtonDialog:new{
        title = _("Groups"),
        buttons = rows,
    }
    UIManager:show(dialog)
end

--- Book Settings entry for one book. opts: { plugin, ui, on_close }
function GroupsUI.showBookRow(path, opts)
    opts = opts or {}
    local ButtonDialog = require("ui/widget/buttondialog")
    local BookGroups = groups()
    local memberships = BookGroups.groupsFor(path)
    local dialog
    local function reopen()
        UIManager:close(dialog)
        GroupsUI.showBookRow(path, opts)
    end
    local rows = {}
    for _idx, group in ipairs(memberships) do
        local captured = group
        local pos = BookGroups.positionOf(captured, path)
        rows[#rows + 1] = {{
            -- Round 30: only a SERIES has a book number — saying "book 2 of 5"
            -- about a project or a plain list asserts an order that does not exist
            text = BookGroups.isOrdered(captured)
                and T(_("In %1 (book %2 of %3)"), displayName(captured), pos, #captured.books)
                or T(_("In %1 (%2 books)"), displayName(captured), #captured.books),
            align = "left",
            callback = function()
                UIManager:close(dialog)
                GroupsUI.showGroup(captured.id, {
                    plugin = opts.plugin, ui = opts.ui,
                    on_close = reopen,
                })
            end,
        }}
    end
    -- Join an existing group this book isn't in yet
    local joinable = {}
    for _idx, group in ipairs(BookGroups.all()) do
        if not BookGroups.positionOf(group, path) then
            joinable[#joinable + 1] = group
        end
    end
    for _idx, group in ipairs(joinable) do
        local captured = group
        rows[#rows + 1] = {{
            text = T(_("Add to %1"), displayName(captured)),
            align = "left",
            callback = function()
                BookGroups.addBook(captured.id, path)
                reopen()
            end,
        }}
    end
    rows[#rows + 1] = {{
        text = _("New group with this book…"),
        callback = function()
            UIManager:close(dialog)
            -- Kenken QoL (#90): prefill with this book's title — deleting a
            -- few characters beats typing CJK on an e-reader keyboard
            promptName(_("New group"), BookGroups.displayTitle(path, opts.ui), function(name)
                createWithKind(name, function(group)
                    groups().addBook(group.id, path)
                    GroupsUI.showBookRow(path, opts)
                end)
            end, function() GroupsUI.showBookRow(path, opts) end)
        end,
    }}
    -- P5 item 7: series suggest for THIS book (Book Settings / Book Hub entry)
    local series_row = seriesSuggestRow(path,
        function() UIManager:close(dialog) end,
        { plugin = opts.plugin, ui = opts.ui, on_close = reopen })
    if series_row then rows[#rows + 1] = { series_row } end
    rows[#rows + 1] = {{
        text = _("Back"),
        callback = function()
            UIManager:close(dialog)
            if opts.on_close then opts.on_close() end
        end,
    }}
    dialog = ButtonDialog:new{
        title = T(_("Groups — %1"), BookGroups.displayTitle(path, opts.ui)),
        buttons = rows,
    }
    UIManager:show(dialog)
end

return GroupsUI
