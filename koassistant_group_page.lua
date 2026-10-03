--[[--
Group pages (G0, docs/group_hub_plan.md, 2026-09-06): two full-screen
singletons in the Book Hub's shape.

- The GROUP HUB: THE per-group screen — GroupsUI.showGroup opens it, so every
  entry point and every group flow's reopen lands here. Rows: the ACTION
  rows first (Group Settings… = koassistant_group_settings.lua, the fold
  row, the kind-named Chat/Action row) so a long book list never pushes them onto the next
  page, then a dim hint and the members in order (tap = that book's Book
  Hub, hold = the move / open / remove dialog; the open book's row says
  "open"), and LAST the add rows (Add books…, Add all books in a folder…,
  Add all books in a collection…). The title-bar hamburger is an anchored dropdown
  (round 7, the list's shape): the add flows again, Kind: X… (the stacked
  radio popup), Rename…, Delete group…. Subtitle = the members' authors, the
  kind and the count. Up-arrow = the Groups list.
- The GROUPS LIST: THE all-groups screen — GroupsUI.showManager opens it.
  Rows: a dim hint, every group with its kind's emoji and "Kind · N books"
  on the right (tap = its hub, hold = the group's management popup,
  GroupsUI.showGroupDialog with the move arrows), then New group…, New group
  from folder…, New group from collection…, and with a book open New group
  with this book… + the series suggestion. The title-bar hamburger is an
  anchored dropdown: the create rows again and "Sort groups…" — one-shot
  reorders of the stored list by name or by kind (groups stay movable by
  hand; sorting is an action, not a second state).

Both are strictly VIEWS: nothing generated, nothing stored. Group settings
(G1) and the series view (G3) arrive as hub rows.

Stacking rule: overlays (pickers, dialogs, the library input dialog, a
member's Book Hub, an X-Ray browser a fold opens, the hub over the list)
stack on top, and a page REBUILDS its rows on the repaint that reveals it
again (the Book Hub's paintTo hook + stale flag). The flows' reopen calls
(`GroupsUI.showGroup` / `GroupsUI.showManager`) mark the page stale instead
of reopening; entry points pass `front = true` for a fresh page on top.
Closing a page runs opts.on_close (the per-book screen's or Book Settings'
reopen), except when code closes it (a deleted group, the up-arrow, the
book-open ghost sweep in main.lua, which nils `_menu` / `_list_menu`).
]]

local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local Constants = require("koassistant_constants")
local T = require("ffi/util").template
local _ = require("koassistant_gettext")
local logger = require("koassistant_logger")

local GroupPage = {}

local function groups() return require("koassistant_book_groups") end
local function groupsUI() return require("koassistant_book_groups_ui") end

-- Conditional emoji: the Book Hub's rule (only with the icons setting on)
local function E(emoji, text, enable) return Constants.getEmojiText(emoji, text, enable) end

local function emojiSetting(plugin, given)
    if given ~= nil then return given end
    local f = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
    return f.enable_emoji_icons == true
end

-- One emoji per kind on the list (maintainer): a stack of books for a
-- series, an open folder for a project, the card box for a plain list
local function kindEmoji(kind)
    local BookGroups = groups()
    if kind == BookGroups.KIND_SERIES then return "\u{1F4DA}" end
    if kind == BookGroups.KIND_PROJECT then return "\u{1F4C2}" end
    return "\u{1F5C2}\u{FE0F}"
end

-- The title-bar hamburger's dropdown (round 7, both pages): anchored under
-- the icon, sized to its rows — the action managers' recipe. rows = { {
-- text, callback, enabled } }
local function anchoredMenu(menu, rows)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for _idx, r in ipairs(rows) do
        local fn = r.callback
        buttons[#buttons + 1] = {{
            text = r.text,
            enabled = r.enabled,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                fn()
            end,
        }}
    end
    dialog = ButtonDialog:new{
        buttons = buttons,
        shrink_unneeded_width = true,
        anchor = function()
            return menu.title_bar.left_button.image.dimen, true
        end,
    }
    UIManager:show(dialog)
end

-- "Series · 3 books": the hub's subtitle tail and the list rows' right column
local function kindCount(kind, n)
    local label = groupsUI().kindLabel(kind)
    if n == 1 then return T(_("%1 · 1 book"), label) end
    return T(_("%1 · %2 books"), label, n)
end

-- ---------------------------------------------------------------- page plumbing
-- Two singletons share it: slot "" = the hub (fields _menu/_ctx/…), slot
-- "_list" = the groups list (_list_menu/_list_ctx/…). The ghost sweep in
-- main.lua closes both by field name.
local function closePage(slot, opts)
    local menu = GroupPage[slot .. "_menu"]
    if not menu then return end
    GroupPage[slot .. "_silent"] = (opts and opts.silent) and true or nil
    UIManager:close(menu)
end

--- Open a page, or refresh the open one when it already shows `ctx.key`
--- (the flows' reopen; `ctx.front` forces a fresh page on top).
--- build(ctx) → { title, subtitle, items } or nil (gone).
--- extra: { hamburger = fn(ctx), on_return = fn(ctx) }
local function openPage(slot, ctx, build, extra)
    local mk, ck, sk = slot .. "_menu", slot .. "_ctx", slot .. "_stale"
    local cur = GroupPage[ck]
    if GroupPage[mk] and cur and cur.key == ctx.key and not ctx.front then
        GroupPage[sk] = true
        UIManager:setDirty(GroupPage[mk], "ui")
        return
    end
    closePage(slot, { silent = true })
    GroupPage[ck] = ctx
    GroupPage[sk] = nil
    local first = build(ctx)
    if not first then GroupPage[ck] = nil return end
    extra = extra or {}
    local menu
    menu = Menu:new{
        title = first.title,
        subtitle = first.subtitle,
        item_table = first.items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        single_line = true,
        items_font_size = 18,
        items_mandatory_font_size = 14,
        title_bar_left_icon = extra.hamburger and "appbar.menu" or nil,
        onLeftButtonTap = extra.hamburger and function() extra.hamburger(ctx, menu) end or nil,
        onReturn = extra.on_return and function() extra.on_return(ctx) end or nil,
        -- NOTE: no close_callback — Menu fires it after EVERY item tap (the
        -- Book Hub's trap); on_close rides onCloseWidget below
        onMenuSelect = function(_menu, item)
            if item and item.callback then
                GroupPage[sk] = true
                item.callback()
            end
            return true
        end,
        onMenuHold = function(_menu, item)
            if item and item.hold_callback then
                GroupPage[sk] = true
                item.hold_callback()
            end
            return true
        end,
    }
    GroupPage[mk] = menu
    if extra.on_return then
        -- The bottom-left return arrow shows with onReturn and enables with a
        -- non-empty path trace (the X-Ray browser's seed)
        table.insert(menu.paths, true)
        menu:updatePageInfo()
    end
    local orig_onCloseWidget = menu.onCloseWidget
    menu.onCloseWidget = function(menu_self)
        local mine = GroupPage[mk] == menu_self
        local silent = GroupPage[slot .. "_silent"]
        GroupPage[slot .. "_silent"] = nil
        local on_close = mine and GroupPage[ck] and GroupPage[ck].on_close or nil
        if mine then GroupPage[mk] = nil end
        -- The ghost sweep nils the menu before closing: ours too, silently
        if not GroupPage[mk] then GroupPage[ck] = nil end
        if orig_onCloseWidget then orig_onCloseWidget(menu_self) end
        if mine and not silent and on_close then on_close() end
    end
    -- Lazy in-place refresh: the first repaint after a row opened something
    -- (or a flow asked for a reopen) rebuilds rows + title bar from disk
    -- truth; itemnumber -1 keeps the page the reader was on
    local orig_paintTo = menu.paintTo
    menu.paintTo = function(menu_self, ...)
        if GroupPage[sk] and GroupPage[mk] == menu_self then
            GroupPage[sk] = nil
            local fresh = build(ctx)
            if fresh then
                menu_self:switchItemTable(fresh.title, fresh.items, -1, nil, fresh.subtitle)
            end
        end
        return orig_paintTo(menu_self, ...)
    end
    UIManager:show(menu)
end

-- ---------------------------------------------------------------- the hub
local function authorsLine(authors)
    if #authors == 0 then return nil end
    if #authors == 1 then return authors[1] end
    if #authors == 2 then return authors[1] .. ", " .. authors[2] end
    return T(_("%1, %2 +%3"), authors[1], authors[2], #authors - 2)
end

local function hubBuild(ctx)
    local BookGroups = groups()
    local GroupsUI = groupsUI()
    local group = BookGroups.byId(ctx.group_id)
    if not group then return nil end
    local items = {}
    local flow_opts = { plugin = ctx.plugin, ui = ctx.ui, on_close = ctx.on_close }
    local open_file = ctx.ui and ctx.ui.document and ctx.ui.document.file
    local em = ctx.enable_emoji
    local kind = BookGroups.kindOf(group)
    local function row(text, fn)
        items[#items + 1] = { text = text, callback = fn }
    end
    -- ACTION rows FIRST (round 9, maintainer): the group settings, the fold
    -- and the Chat/Action sit above the members, in a predictable place a
    -- long book list can never push onto the next page.
    -- G1: the settings the group sets for its members (docs/group_hub_plan.md §2.1)
    row(E("\u{2699}\u{FE0F}", require("koassistant_group_settings").rowLabel(ctx.group_id) .. "\u{2026}", em),
        function()
            require("koassistant_group_settings").show({
                group_id = ctx.group_id, plugin = ctx.plugin, ui = ctx.ui,
                on_close = function() GroupsUI.showGroup(ctx.group_id, flow_opts) end,
            })
        end)
    -- A2/A3: the fold surface the kind picker promises — series chain or
    -- project fan-in. Plain groups share nothing by design: no row.
    if #group.books > 1 and ctx.plugin and ctx.plugin._startCrossBookXrayFlow
        and BookGroups.sharesKnowledge(group) then
        -- B394 slice 1: the row says what it costs before it is tapped
        row(E("\u{1F500}", kind == BookGroups.KIND_PROJECT
                and _("Fold X-Rays into one book (1 request per book)…")
                or _("Merge series X-Rays (1 request per book)…"), em),
            function() GroupsUI.foldFlow(ctx.group_id, flow_opts) end)
    end
    -- Item 48(a): the group as launch surface — library chat/actions with the
    -- members pre-selected. Named after the kind (maintainer, G0 round 3),
    -- in the Book Hub's "Book Chat/Action" shape with its 💬.
    if #group.books > 0 and ctx.plugin and ctx.plugin.openLibraryDialogForGroup then
        local chat_label = kind == BookGroups.KIND_PROJECT and _("Project Chat/Action…")
            or kind == BookGroups.KIND_SERIES and _("Series Chat/Action…")
            or _("Group Chat/Action…")
        row(E("\u{1F4AC}", chat_label, em),
            function() ctx.plugin:openLibraryDialogForGroup(ctx.group_id) end)
    end
    -- Help line above the members (maintainer): the hold gesture is the one
    -- thing a reader cannot see
    items[#items + 1] = {
        text = _("Tap a book for its hub. Hold it to move, open or remove it."),
        dim = true,
        callback = function() end,
    }
    local authors, seen = {}, {}
    for i, path in ipairs(group.books) do
        local captured = path
        local raw_title, author = BookGroups.displayProps(captured, ctx.ui)
        if author then
            -- KOReader joins several authors with newlines; the first one names the book
            local first = author:match("^[^\n]+") or author
            if not seen[first] then
                seen[first] = true
                authors[#authors + 1] = first
            end
        end
        local title = raw_title
        if not BookGroups.fileExists(captured) then
            title = title .. " " .. _("(missing)")
        end
        items[#items + 1] = {
            text = E("\u{1F4D6}", i .. ". " .. title, em),
            mandatory = captured == open_file and _("open") or nil,
            callback = function()
                -- A member row opens the member's Book Hub; it stacks over this
                -- page, and its up-arrow comes back here
                require("koassistant_book_page").show({
                    file = captured, plugin = ctx.plugin, ui = ctx.ui,
                    title = raw_title, author = author, enable_emoji = em,
                })
            end,
            hold_callback = function()
                GroupsUI.showMoveDialog(ctx.group_id, captured, flow_opts)
            end,
        }
    end
    if #group.books == 0 then
        items[#items + 1] = {
            text = _("No books yet. Add some below."),
            dim = true,
            callback = function() end,
        }
    end
    -- The add rows LAST (round 8, maintainer): the hamburger has them too,
    -- and they must never push the action rows around
    row(E("\u{2795}", _("Add books…"), em),
        function() GroupsUI.addBooksFlow(ctx.group_id, flow_opts) end)
    row(E("\u{2795}", _("Add all books in a folder…"), em),
        function() GroupsUI.addFolderFlow(ctx.group_id, flow_opts) end)
    if GroupsUI.hasCollections() then
        row(E("\u{2795}", _("Add all books in a collection…"), em),
            function() GroupsUI.addCollectionFlow(ctx.group_id, flow_opts) end)
    end
    local subtitle = kindCount(kind, #group.books)
    local by = authorsLine(authors)
    if by then subtitle = by .. " \u{00B7} " .. subtitle end
    return { title = GroupsUI.displayName(group), subtitle = subtitle, items = items }
end

-- Title-bar hamburger (round 7, maintainer: the same setup as the list's):
-- an anchored dropdown with the add flows, then Kind: X… (the stacked radio
-- popup), Rename…, Delete group…. Flows land back here through their default
-- tail (GroupsUI.showGroup = this hub's refresh).
local function hubHamburger(ctx, menu)
    local BookGroups = groups()
    local GroupsUI = groupsUI()
    local group = BookGroups.byId(ctx.group_id)
    if not group then return end
    GroupPage._stale = true
    local flow_opts = { plugin = ctx.plugin, ui = ctx.ui, on_close = ctx.on_close }
    local rows = {
        { text = _("Add books…"), callback = function() GroupsUI.addBooksFlow(ctx.group_id, flow_opts) end },
        { text = _("Add all books in a folder…"),
            callback = function() GroupsUI.addFolderFlow(ctx.group_id, flow_opts) end },
    }
    if GroupsUI.hasCollections() then
        rows[#rows + 1] = { text = _("Add all books in a collection…"),
            callback = function() GroupsUI.addCollectionFlow(ctx.group_id, flow_opts) end }
    end
    rows[#rows + 1] = { text = T(_("Kind: %1…"), GroupsUI.kindLabel(BookGroups.kindOf(group))),
        callback = function() GroupsUI.showKindDialog(ctx.group_id, flow_opts) end }
    rows[#rows + 1] = { text = _("Rename…"),
        callback = function() GroupsUI.renameFlow(ctx.group_id, flow_opts) end }
    rows[#rows + 1] = { text = _("Delete group…"),
        callback = function() GroupsUI.deleteFlow(ctx.group_id, flow_opts) end }
    anchoredMenu(menu, rows)
end

--- Close the hub. opts.silent = do not run on_close (code-driven closes).
function GroupPage.close(opts) closePage("", opts) end

--- Show (or refresh) the hub for one group.
--- @param opts table { group_id (required), plugin, ui, on_close, front,
---   enable_emoji (nil = the icons setting) }
function GroupPage.show(opts)
    local group_id = opts and opts.group_id
    if not group_id then return end
    if not groups().byId(group_id) then
        -- Gone (the delete flow's reopen lands here): drop the page and hand
        -- control back the way the old screen did
        local on_close = (GroupPage._ctx and GroupPage._ctx.on_close) or opts.on_close
        GroupPage.close({ silent = true })
        if on_close then on_close() end
        return
    end
    logger.dbg("KOAssistant GroupHub: show", group_id)
    openPage("", {
        key = group_id, group_id = group_id, plugin = opts.plugin, ui = opts.ui,
        on_close = opts.on_close, front = opts.front,
        enable_emoji = emojiSetting(opts.plugin, opts.enable_emoji),
    }, hubBuild, {
        hamburger = hubHamburger,
        on_return = function(ctx)
            -- Up = the Groups list: refreshed underneath when the hub was
            -- opened from it, fresh otherwise (on_close stays unrun: this is
            -- navigation, not a close)
            GroupPage.close({ silent = true })
            GroupPage.showList({ plugin = ctx.plugin, ui = ctx.ui, enable_emoji = ctx.enable_emoji })
        end,
    })
end

-- ---------------------------------------------------------------- the list
local function listOpts(ctx)
    return { plugin = ctx.plugin, ui = ctx.ui, enable_emoji = ctx.enable_emoji }
end

-- Hold on a group row = the group's management popup with the move arrows
-- (GroupsUI.showGroupDialog); its flows refresh THIS list, since no hub is
-- open underneath
local function listHold(ctx, group_id)
    groupsUI().showGroupDialog(group_id, {
        plugin = ctx.plugin, ui = ctx.ui, arrows = true,
        after = function() GroupPage.showList(listOpts(ctx)) end,
    })
end

local function listHamburger(ctx, menu)
    local ButtonDialog = require("ui/widget/buttondialog")
    local GroupsUI = groupsUI()
    local flow_opts = { plugin = ctx.plugin, ui = ctx.ui }
    GroupPage._list_stale = true
    local rows = {
        { text = _("New group…"), callback = function() GroupsUI.newGroupFlow(flow_opts) end },
        { text = _("New group from folder…"),
            callback = function() GroupsUI.newGroupFromFolderFlow(flow_opts) end },
    }
    if GroupsUI.hasCollections() then
        rows[#rows + 1] = { text = _("New group from collection…"),
            callback = function() GroupsUI.newGroupFromCollectionFlow(flow_opts) end }
    end
    local open_file = ctx.ui and ctx.ui.document and ctx.ui.document.file
    if open_file then
        rows[#rows + 1] = { text = _("New group with this book…"),
            callback = function() GroupsUI.newGroupWithBookFlow(open_file, flow_opts) end }
    end
    -- One-shot sorts (round 6: by name or by kind): each rewrites the stored
    -- order once; moving by hand goes on working afterwards. The picker's own
    -- line stands in for a confirm.
    rows[#rows + 1] = { text = _("Sort groups…"), enabled = #groups().all() > 1,
        callback = function()
            local sort_dialog
            local function by(mode, label)
                return {{ text = label, callback = function()
                    UIManager:close(sort_dialog)
                    groups().sortGroups(mode, GroupsUI.displayName)
                    GroupPage.showList(listOpts(ctx))
                end }}
            end
            sort_dialog = ButtonDialog:new{
                title = _("Sort groups") .. "\n" .. _("You can still move them by hand afterwards."),
                buttons = {
                    by("name", _("By name")),
                    by("kind", _("By kind, then name")),
                    {{ text = _("Cancel"), callback = function() UIManager:close(sort_dialog) end }},
                },
            }
            UIManager:show(sort_dialog)
        end }
    anchoredMenu(menu, rows)
end

local function listBuild(ctx)
    local BookGroups = groups()
    local GroupsUI = groupsUI()
    local items = {}
    local em = ctx.enable_emoji
    local list = BookGroups.all()
    if #list > 0 then
        items[#items + 1] = {
            text = _("Tap a group for its hub. Hold it to move, rename or delete it."),
            dim = true,
            callback = function() end,
        }
    end
    for _idx, group in ipairs(list) do
        local captured = group
        local kind = BookGroups.kindOf(captured)
        items[#items + 1] = {
            text = E(kindEmoji(kind), GroupsUI.displayName(captured), em),
            mandatory = kindCount(kind, #captured.books),
            callback = function()
                GroupsUI.showGroup(captured.id, { plugin = ctx.plugin, ui = ctx.ui,
                    front = true, enable_emoji = em })
            end,
            hold_callback = function() listHold(ctx, captured.id) end,
        }
    end
    if #list == 0 then
        items[#items + 1] = {
            text = _("No groups yet. A group is an ordered set of books: a series, an author, a project."),
            dim = true,
            callback = function() end,
        }
    end
    local flow_opts = { plugin = ctx.plugin, ui = ctx.ui }
    local function row(text, fn)
        items[#items + 1] = { text = text, callback = fn }
    end
    row(E("\u{2795}", _("New group…"), em), function() GroupsUI.newGroupFlow(flow_opts) end)
    row(E("\u{2795}", _("New group from folder…"), em),
        function() GroupsUI.newGroupFromFolderFlow(flow_opts) end)
    if GroupsUI.hasCollections() then
        row(E("\u{2795}", _("New group from collection…"), em),
            function() GroupsUI.newGroupFromCollectionFlow(flow_opts) end)
    end
    local open_file = ctx.ui and ctx.ui.document and ctx.ui.document.file
    if open_file then
        row(E("\u{2795}", _("New group with this book…"), em),
            function() GroupsUI.newGroupWithBookFlow(open_file, flow_opts) end)
        -- P5 item 7: the open book's series tag, one tap to a group named
        -- after it (then the find-the-rest scan)
        local series_row = GroupsUI.seriesRowFor(open_file, flow_opts)
        if series_row then row(E("\u{2795}", series_row.text, em), series_row.callback) end
    end
    return { title = _("Groups"), items = items }
end

--- Close the list. opts.silent = do not run on_close.
function GroupPage.closeList(opts) closePage("_list", opts) end

--- Show (or refresh) the Groups list.
--- @param opts table { plugin, ui, on_close, front, enable_emoji }
function GroupPage.showList(opts)
    opts = opts or {}
    logger.dbg("KOAssistant GroupHub: list")
    openPage("_list", {
        key = "list", plugin = opts.plugin, ui = opts.ui,
        on_close = opts.on_close, front = opts.front,
        enable_emoji = emojiSetting(opts.plugin, opts.enable_emoji),
    }, listBuild, { hamburger = listHamburger })
end

return GroupPage
