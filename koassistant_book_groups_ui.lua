--[[--
Book groups manager UI (xray_ecosystem_plan.md item 46, ref #90).

Small ButtonDialog stack over koassistant_book_groups.lua:
- showManager: since G0 round 2 the GROUPS LIST page (koassistant_group_page.lua
  showList) whose rows call the create flows this file exports (newGroupFlow,
  newGroupFromFolderFlow, newGroupWithBookFlow, seriesRowFor); the old
  ButtonDialog manager is retired.
- showGroup: since G0 (2026-09-06, docs/group_hub_plan.md) the GROUP HUB —
  koassistant_group_page.lua, a full-screen Menu in the Book Hub's shape —
  whose rows call the flows this file exports (addBooksFlow, addFolderFlow,
  foldFlow, renameFlow, deleteFlow, showMoveDialog) and whose hamburger opens
  showGroupDialog, the group's management popup (also the Groups list's hold;
  G0 round 4). The old ButtonDialog screen is retired; every flow still ends
  with GroupsUI.showGroup, which refreshes the hub in place, or with the
  caller's own `opts.after` refresh (the list).
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
    -- B394 slice 1: each sentence true of what the code does. The project
    -- text used to say "nothing is carried forward automatically", while a
    -- project has seeded every member's carried list from every other member
    -- since 2026-09-02.
    if kind == BookGroups.KIND_PROJECT then
        return _("Books on one subject, in no order. What each book's X-Ray knows is carried into every other book on its own. Nothing is held back.")
    end
    if kind == BookGroups.KIND_PLAIN then
        return _("Just a list. The books share a hub, a group chat and group settings. Nothing is carried between their X-Rays; an AI merge between any two is still available.")
    end
    return _("Books in reading order, one continued story. What the earlier books' X-Rays know is carried into the later books on its own. A later book stays out of reach until the books before it are read.")
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
            .. _("Series: reading order, one story. Earlier books' knowledge is carried forward.") .. "\n"
            .. _("Project: one subject, no order. Knowledge is carried between all the books.") .. "\n"
            .. _("Plain: just a list. Nothing is carried."),
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

--- Any KOReader collection exists (the collection rows' gate). The
--- collection helpers live in koassistant_book_picker.lua since round 7 —
--- the picker browses collections as a source, the flows below reuse its
--- pickCollection / collectionBooks.
function GroupsUI.hasCollections()
    return require("koassistant_book_picker").hasCollections()
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
            -- A tap outside is Cancel, as in offerSeriesScan (B360)
            tap_close_callback = done,
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
    if GroupsUI.hasCollections() then
        rows[#rows + 1] = {{
            text = _("Look in a collection…"),
            callback = function()
                UIManager:close(dialog)
                require("koassistant_book_picker").pickCollection(function(_name, label, paths)
                    runSeriesScan(group_id, seed_path, sp, paths, label, opts)
                end, done)
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
                -- B394 slice 1: straight to the fold's confirm (it used to
                -- open the merge picker, whose first row was this fold)
                if opts.plugin._startGroupXrayMergeFlow then
                    opts.plugin:_startGroupXrayMergeFlow("project", captured)
                else
                    opts.plugin:_startCrossBookXrayFlow(captured)
                end
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
        title = _("AI merge the group's X-Rays into which book?") .. "\n"
            .. _("Knowledge flows INTO the book you pick. The others are not changed. One request per other book."),
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
    -- One line's worth: ButtonDialog titles wrap, and a long book title used
    -- to push the buttons down the screen (G0 round 4)
    local title = BookGroups.shortName(BookGroups.displayTitle(path, opts.ui))
    local book_dialog
    -- G0: showGroup refreshes the hub underneath in place
    local function refreshBoth()
        UIManager:close(book_dialog)
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
                        GroupsUI.showGroup(group_id, opts)
                    end,
                    -- Every way out (Move, Cancel, a tap outside) comes back
                    -- to the move dialog: SpinWidget runs close_callback on
                    -- each close, after the Move callback (B360)
                    close_callback = function()
                        GroupsUI.showMoveDialog(group_id, path, opts)
                    end,
                })
            end }},
            -- Groups double as navigation: jump to the member you want to
            -- work on (device request 2026-08-05)
            {{ text = _("Open this book"), enabled = BookGroups.fileExists(path),
                callback = function()
                    UIManager:close(book_dialog)
                    -- The hub underneath is swept at book open (main.lua)
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

--- The group's management popup (G0 rounds 4+5, maintainer): the member move
--- dialog's shape AND width — narrow (shrink_unneeded_width), one button per
--- row, so the list behind stays readable while a group is moved. Title = the
--- name on one line. Rows: ↑/↓ when opened from the Groups list (opts.arrows),
--- "Kind: X…" → showKindDialog stacked on top, Rename…, Delete group…, Done.
--- No position line, no "Move to position…" (a list of groups is short). A
--- change re-shows the popup ANCHORED at its own top-left (opts.at). Reached
--- by HOLD on a Groups list row and by the hub's title-bar hamburger.
--- opts: { plugin, ui, after (the host's refresh; nil = the hub's), on_close,
---   arrows, at (internal: the top-left to re-show at) }
function GroupsUI.showGroupDialog(group_id, opts)
    opts = opts or {}
    local ButtonDialog = require("ui/widget/buttondialog")
    local Geom = require("ui/geometry")
    local BookGroups = groups()
    local group = BookGroups.byId(group_id)
    if not group then return end
    local name = BookGroups.shortName(displayName(group))
    local dialog
    local function refresh()
        if opts.after then opts.after() else GroupsUI.showGroup(group_id, opts) end
    end
    local function reshow()
        local d = dialog.movable and dialog.movable.dimen
        local at = d and { x = d.x, y = d.y } or opts.at
        UIManager:close(dialog)
        refresh()
        local again = {}
        for k, v in pairs(opts) do again[k] = v end
        again.at = at
        GroupsUI.showGroupDialog(group_id, again)
    end
    local function flow(fn)
        return function()
            UIManager:close(dialog)
            fn()
        end
    end
    local rows = {}
    if opts.arrows then
        local i, n = BookGroups.groupIndex(group_id)
        rows[#rows + 1] = {
            { text = "\u{2191}", enabled = i ~= nil and i > 1, callback = function()
                BookGroups.moveGroup(group_id, -1)
                reshow()
            end },
            { text = "\u{2193}", enabled = i ~= nil and i < n, callback = function()
                BookGroups.moveGroup(group_id, 1)
                reshow()
            end },
        }
    end
    rows[#rows + 1] = {{ text = T(_("Kind: %1…"), GroupsUI.kindLabel(BookGroups.kindOf(group))),
        callback = function()
            -- Stacked: this popup stays underneath and re-reads its row when
            -- the kind popup closes (Done or tap-outside)
            GroupsUI.showKindDialog(group_id, opts, reshow)
        end }}
    rows[#rows + 1] = {{ text = _("Group settings…"),
        callback = flow(function()
            require("koassistant_group_settings").show({
                group_id = group_id, plugin = opts.plugin, ui = opts.ui,
                on_close = refresh,
            })
        end) }}
    rows[#rows + 1] = {{ text = _("Rename…"),
        callback = flow(function() GroupsUI.renameFlow(group_id, opts) end) }}
    rows[#rows + 1] = {{ text = _("Delete group…"),
        callback = flow(function() GroupsUI.deleteFlow(group_id, opts) end) }}
    rows[#rows + 1] = {{ text = _("Done"), callback = function() UIManager:close(dialog) end }}
    local at = opts.at
    dialog = ButtonDialog:new{
        title = name,
        buttons = rows,
        shrink_unneeded_width = true,
        anchor = at and function() return Geom:new{ x = at.x, y = at.y, w = 0, h = 0 }, true end or nil,
    }
    UIManager:show(dialog)
end

--- The kind radio (round 5): the name and the CURRENT kind's description as
--- the title, the three kinds on one row (●/○), Done. A tap sets the kind at
--- once and re-shows this popup anchored at its own top-left, so the
--- description re-reads in place and a longer sentence grows downward
--- instead of re-centering the window. Default width (the row needs it; the
--- management popup underneath is what stays narrow). on_done runs when the
--- popup closes by Done or by a tap outside — the host popup re-reads its
--- "Kind: X…" row there.
function GroupsUI.showKindDialog(group_id, opts, on_done, at)
    opts = opts or {}
    local ButtonDialog = require("ui/widget/buttondialog")
    local Geom = require("ui/geometry")
    local BookGroups = groups()
    local group = BookGroups.byId(group_id)
    if not group then return end
    local kind = BookGroups.kindOf(group)
    local name = BookGroups.shortName(displayName(group))
    local dialog
    local radio = {}
    for _idx, k in ipairs({ BookGroups.KIND_SERIES, BookGroups.KIND_PROJECT,
            BookGroups.KIND_PLAIN }) do
        local captured = k
        radio[#radio + 1] = {
            text = (captured == kind and "\u{25CF} " or "\u{25CB} ") .. GroupsUI.kindLabel(captured),
            callback = function()
                if captured == kind then return end
                local d = dialog.movable and dialog.movable.dimen
                local pos = d and { x = d.x, y = d.y } or at
                UIManager:close(dialog)
                BookGroups.setKind(group_id, captured)
                if opts.after then opts.after() else GroupsUI.showGroup(group_id, opts) end
                GroupsUI.showKindDialog(group_id, opts, on_done, pos)
            end,
        }
    end
    dialog = ButtonDialog:new{
        title = name .. "\n" .. GroupsUI.kindDescription(kind),
        buttons = {
            radio,
            {{ text = _("Done"), callback = function()
                UIManager:close(dialog)
                if on_done then on_done() end
            end }},
        },
        tap_close_callback = on_done,
        anchor = at and function() return Geom:new{ x = at.x, y = at.y, w = 0, h = 0 }, true end or nil,
    }
    UIManager:show(dialog)
end

--- The group flows (G0, 2026-09-06 — docs/group_hub_plan.md): the old
--- per-group ButtonDialog's actions, factored out so the Group Hub's rows run
--- the SAME code. Each ends where the old dialog's did — with
--- `GroupsUI.showGroup(group_id, opts)`, which now refreshes the hub in place
--- (or hands control back through opts.on_close once the group is gone).
--- opts: { plugin, ui, on_close } as showGroup receives them. G0 round 3:
--- rename / kind / delete also run from the Groups LIST's hold dialog, where
--- no hub is open — those callers pass `opts.after` (the list's refresh) and
--- the flow ends there instead.

-- Round 29: the picker hands back a SET (hash keyed by path), so a plain
-- pairs() loop added books in ARBITRARY order — for a 30-volume folder the
-- reading order came out scrambled, which is the one thing a series group
-- must get right. Adds now go in natural filename order (vol 2 before vol
-- 10) and always APPEND, never splice: a hand-tuned order survives, and
-- one move fixes a stray.
-- Shared tail for every add path: name an unnamed group after its first
-- book (kenken QoL #90 — CJK typing is painful in KOReader), report, reopen.
-- `added` = the paths that joined (G1: the join ask needs them, not a count)
local function addedDone(group_id, opts, added)
    local BookGroups = groups()
    local g = BookGroups.byId(group_id)
    if g and (g.name == "?" or g.name == "") and g.books[1] then
        BookGroups.rename(group_id, BookGroups.displayTitle(g.books[1], opts.ui))
    end
    if added and #added > 0 then
        UIManager:show(require("ui/widget/notification"):new{
            text = T(_("Added %1 book(s)."), #added),
        })
    end
    GroupsUI.showGroup(group_id, opts)
    -- G1 (Q-A, "ask on add"): a group that sets values asks once per batch
    if added and #added > 0 then
        require("koassistant_group_settings").offerJoin(group_id, added,
            { plugin = opts.plugin, ui = opts.ui },
            function() GroupsUI.showGroup(group_id, opts) end)
    end
end
local function addSelected(group_id, opts, selected_files)
    local BookPicker = require("koassistant_book_picker")
    local BookGroups = groups()
    local added = {}
    for _idx, path in ipairs(BookPicker.orderedSelection(selected_files)) do
        if BookGroups.addBook(group_id, path) then added[#added + 1] = path end
    end
    addedDone(group_id, opts, added)
end

-- B407: every picker a hub's add row opens stays on that row's source
-- (fixed_source). "Add from history…" used to open a picker whose menu also
-- browsed folders and collections, so the row's name was untrue and the two
-- rows under it were the same thing twice.
function GroupsUI.addBooksFlow(group_id, opts)
    local BookPicker = require("koassistant_book_picker")
    BookPicker:show({
        fixed_source = true,
        on_confirm = function(selected_files) addSelected(group_id, opts, selected_files) end,
        on_close = function() GroupsUI.showGroup(group_id, opts) end,
    })
end

-- Kenken (#90): "designate a folder as a group" without ticking every box.
-- Round 29 second pass (maintainer: adding a library SCAN folder shows no
-- list, why does this?): because a scan folder stores the FOLDER PATH and
-- re-resolves it per request, while a group stores MEMBER PATHS and must
-- enumerate. So enumerate silently: chooser → one confirm naming the count
-- → done. No list. The confirm stays because this appends to a possibly
-- hand-ordered group and a mis-tapped folder could add hundreds of books;
-- curated picking is what "Add from history…" above is for.
-- Snapshot only: the group does not follow the folder afterwards (live
-- binding is a separate, opt-in idea).
-- B405: the same chooser adds ONE book. A book that is not in the history
-- took nine taps through "Add books…" (the picker, its menu, the folder, a
-- tick, the menu again, confirm); here it is the browse and two taps.
function GroupsUI.addFolderFlow(group_id, opts)
    local BookGroups = groups()
    local PathChooser = require("ui/widget/pathchooser")
    local Device = require("device")
    local DataStorage = require("datastorage")
    local picked = false
    UIManager:show(PathChooser:new{
        title = _("Tap a book, or long-press a folder for all its books"),
        path = G_reader_settings:readSetting("home_dir")
            or Device.home_dir or DataStorage:getDataDir(),
        select_directory = true,
        select_file = true,
        file_filter = function(filename)
            return require("document/documentregistry"):hasProvider(filename)
        end,
        -- KOReader's chooser answers only a long-press on a file; a tap asks
        -- its "Choose this file?" here too
        onMenuSelect = function(chooser, item)
            if item and item.is_file then return chooser:onMenuHold(item) end
            return PathChooser.onMenuSelect(chooser, item)
        end,
        onConfirm = function(folder)
            picked = true
            if require("libs/libkoreader-lfs").attributes(folder, "mode") == "file" then
                local added = {}
                if BookGroups.addBook(group_id, folder) then
                    added[1] = folder
                else
                    UIManager:show(require("ui/widget/notification"):new{
                        text = _("That book is already in this group."),
                    })
                end
                addedDone(group_id, opts, added)
                return
            end
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
                        local added = {}
                        for _idx, path in ipairs(paths) do
                            if BookGroups.addBook(group_id, path) then added[#added + 1] = path end
                        end
                        addedDone(group_id, opts, added)
                    end }},
                    {{ text = _("Choose which…"), callback = function()
                        UIManager:close(ask)
                        BookPicker:show({
                            initial_source = folder,
                            select_all = true,
                            fixed_source = true,
                            on_confirm = function(selected_files) addSelected(group_id, opts, selected_files) end,
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
end

-- Round 6: a collection as the source — the folder flow's shape, in the
-- COLLECTION's order; round 7: "Choose which…" opens the picker on the
-- collection source with everything ticked, like the folder arm
function GroupsUI.addCollectionFlow(group_id, opts)
    local BookGroups = groups()
    local BookPicker = require("koassistant_book_picker")
    BookPicker.pickCollection(function(name, label, paths)
        if #paths == 0 then
            UIManager:show(require("ui/widget/infomessage"):new{
                text = T(_("No books in the collection \"%1\"."), label),
                timeout = 3,
            })
            GroupsUI.showGroup(group_id, opts)
            return
        end
        local ButtonDialog = require("ui/widget/buttondialog")
        local ask
        ask = ButtonDialog:new{
            title = T(_("Add %1 book(s) from the collection \"%2\" to this group, in the collection's order?"),
                #paths, label),
            buttons = {
                {{ text = T(_("Add all (%1)"), #paths), callback = function()
                    UIManager:close(ask)
                    local added = {}
                    for _idx, path in ipairs(paths) do
                        if BookGroups.addBook(group_id, path) then added[#added + 1] = path end
                    end
                    addedDone(group_id, opts, added)
                end }},
                {{ text = _("Choose which…"), callback = function()
                    UIManager:close(ask)
                    BookPicker:show({
                        initial_source = BookPicker.COLLECTION_PREFIX .. name,
                        select_all = true,
                        fixed_source = true,
                        on_confirm = function(selected_files) addSelected(group_id, opts, selected_files) end,
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
    end, function() GroupsUI.showGroup(group_id, opts) end)
end

-- A2/A3: the fold surface the kind picker promises — series chain or project
-- fan-in, via the cross-book picker (ONE flow owns consent, skip-done
-- accounting and the confirms). Callers gate on sharesKnowledge.
function GroupsUI.foldFlow(group_id, opts)
    local BookGroups = groups()
    local group = BookGroups.byId(group_id)
    if not group or not (opts.plugin and opts.plugin._startCrossBookXrayFlow) then return end
    if BookGroups.kindOf(group) == BookGroups.KIND_PROJECT then
        showFoldTargetPicker(group_id, opts)
        return
    end
    -- Series: the chain runs oldest → newest, so it ends at the LAST member
    -- with an X-Ray and covers the whole series. B394 slice 1: straight to
    -- the chain's confirm (it used to open that book's merge picker, where
    -- the chain was one more row)
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
    if opts.plugin._startGroupXrayMergeFlow then
        opts.plugin:_startGroupXrayMergeFlow("series", target)
    else
        opts.plugin:_startCrossBookXrayFlow(target)
    end
end

-- Where a flow lands: the hub's in-place refresh, or the caller's own
-- refresh (the Groups list) when it passed one
local function flowDone(group_id, opts)
    if opts and opts.after then opts.after() return end
    GroupsUI.showGroup(group_id, opts)
end

function GroupsUI.renameFlow(group_id, opts)
    local BookGroups = groups()
    local group = BookGroups.byId(group_id)
    if not group then return end
    -- Prefill skips the "?" placeholder — nothing worth editing in it
    promptName(_("Rename group"), group.name ~= "?" and group.name or "",
        function(name)
            BookGroups.rename(group_id, name)
            flowDone(group_id, opts)
        end, function() flowDone(group_id, opts) end)
end

function GroupsUI.deleteFlow(group_id, opts)
    local ButtonDialog = require("ui/widget/buttondialog")
    local BookGroups = groups()
    local group = BookGroups.byId(group_id)
    if not group then return end
    local confirm
    confirm = ButtonDialog:new{
        title = T(_("Delete the group \"%1\"?\nBooks and their artifacts are not touched. Only the grouping is removed."), displayName(group)),
        buttons = {
            {{ text = _("Delete"), callback = function()
                UIManager:close(confirm)
                BookGroups.remove(group_id)
                -- The hub finds the group gone and hands control back
                -- (on_close); the list just refreshes
                flowDone(group_id, opts)
            end }},
            {{ text = _("Cancel"), callback = function()
                UIManager:close(confirm)
            end }},
        },
    }
    UIManager:show(confirm)
end

--- Per-group screen = the Group Hub (G0, 2026-09-06): every entry point and
--- every flow's reopen lands here. opts: { plugin, ui, on_close, front } —
--- front = a fresh page on top (entry points); without it an open hub for
--- this group just refreshes in place (the reopen pattern the flows keep).
function GroupsUI.showGroup(group_id, opts)
    opts = opts or {}
    require("koassistant_group_page").show({
        group_id = group_id, plugin = opts.plugin, ui = opts.ui,
        on_close = opts.on_close, front = opts.front,
    })
end

--- The create flows (G0 round 2, 2026-09-06): the old Groups ButtonDialog's
--- actions, factored out so the Groups list page's rows run the SAME code.
--- Each ends where the old dialog's did — with `GroupsUI.showManager(opts)`
--- (now the list's in-place refresh) or with the new group's hub on top.
--- opts: { plugin, ui, on_close }.

function GroupsUI.newGroupFlow(opts)
    promptName(_("New group"), nil, function(name)
        createWithKind(name, function(group)
            GroupsUI.showGroup(group.id, {
                plugin = opts.plugin, ui = opts.ui,
                on_close = function() GroupsUI.showManager(opts) end,
            })
        end)
    end, function() GroupsUI.showManager(opts) end)
end

-- Kenken (#90) round 29 second pass: a folder becomes a group in one go —
-- chooser → name prompt (folder name prefilled, count in the description)
-- → create → every book joins in filename order (snapshot: the group does
-- not follow the folder afterwards); curation is what the hub's rows are for.
function GroupsUI.newGroupFromFolderFlow(opts)
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
end

-- Round 6: the folder flow's shape over a collection — name prefilled with
-- the collection's, all its books join in the collection's order
function GroupsUI.newGroupFromCollectionFlow(opts)
    require("koassistant_book_picker").pickCollection(function(_name, label, paths)
        if #paths == 0 then
            UIManager:show(require("ui/widget/infomessage"):new{
                text = T(_("No books in the collection \"%1\"."), label),
                timeout = 3,
            })
            GroupsUI.showManager(opts)
            return
        end
        promptName(_("New group"), label,
            function(name)
                createWithKind(name, function(group)
                    local added = 0
                    for _idx, p in ipairs(paths) do
                        if groups().addBook(group.id, p) then added = added + 1 end
                    end
                    UIManager:show(require("ui/widget/notification"):new{
                        text = T(_("Added %1 book(s), in the collection's order."), added),
                    })
                    GroupsUI.showGroup(group.id, {
                        plugin = opts.plugin, ui = opts.ui,
                        on_close = function() GroupsUI.showManager(opts) end,
                    })
                end)
            end, function() GroupsUI.showManager(opts) end,
            { description = T(_("%1 book(s) from the collection will be added, in its order."), #paths) })
    end, function() GroupsUI.showManager(opts) end)
end

-- Main-menu parity with Book Settings (kenken round 5): seed a group from
-- the OPEN book — title prefilled, book added on create
function GroupsUI.newGroupWithBookFlow(path, opts)
    local BookGroups = groups()
    promptName(_("New group"), BookGroups.displayTitle(path, opts.ui), function(name)
        createWithKind(name, function(group)
            groups().addBook(group.id, path)
            GroupsUI.showGroup(group.id, {
                plugin = opts.plugin, ui = opts.ui,
                on_close = function() GroupsUI.showManager(opts) end,
            })
        end)
    end, function() GroupsUI.showManager(opts) end)
end

--- The series-suggestion row for a book, as { text, callback } or nil
--- (P5 item 7), for a page that stays open underneath the flow.
function GroupsUI.seriesRowFor(path, opts)
    return seriesSuggestRow(path, function() end,
        { plugin = opts.plugin, ui = opts.ui,
          on_close = function() GroupsUI.showManager(opts) end })
end

--- Top-level manager = the Groups list page (G0 round 2): every entry point
--- and every create flow's reopen lands here. opts: { plugin, ui, on_close,
--- front } — front = a fresh page on top; without it an open list just
--- refreshes in place.
function GroupsUI.showManager(opts)
    opts = opts or {}
    require("koassistant_group_page").showList({
        plugin = opts.plugin, ui = opts.ui, on_close = opts.on_close, front = opts.front,
    })
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
                    plugin = opts.plugin, ui = opts.ui, front = true,
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
                -- G1 (Q-A): a group that sets values asks before the book follows them
                require("koassistant_group_settings").offerJoin(captured.id, { path },
                    { plugin = opts.plugin, ui = opts.ui }, reopen)
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
        title = T(_("Groups: %1"), BookGroups.displayTitle(path, opts.ui)),
        buttons = rows,
        -- A tap outside is Back (B360)
        tap_close_callback = function()
            if opts.on_close then opts.on_close() end
        end,
    }
    UIManager:show(dialog)
end

return GroupsUI
