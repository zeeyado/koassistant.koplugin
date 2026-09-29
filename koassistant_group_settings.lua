--[[--
Group settings (G1, docs/group_hub_plan.md §2.1, 2026-09-07, ref #90).

A group can hold values for the SAME per-book settings a book can (the same
sidecar keys, the same values, the same pickers). Members follow the group
through a marker stored in the book's own setting (`BookStore.marker`, see
koassistant_book_store.lua: readSetting dereferences it, readRaw shows it, any
own write replaces it = "latest set wins"). Setting a value here APPLIES it:
the markers are written into every member behind a confirm naming the
member count and how many had their own value. Followers read the group's
value live; clearing a group value turns its markers into follow-global.
A member whose own pick replaced the marker is OUT OF SYNC: listed on the
screen with "Re-apply to all". Leaving a group (or deleting it) turns that
group's markers on the book into follow-global. Joining a group that has
settings asks once per add (offerJoin).

Wave 1 = domain, research mode, Background, spoiler protection, automatic
X-Ray, the categories and depth of new X-Rays, the three per-book languages
(the chat dials stay per book for now, Q-E in the plan). Nothing new
is defined: every row opens the shared BookSettings picker on a GROUP FACADE
(`GroupSettings.facade`) — an object with the doc_settings surface the
pickers already speak, backed by the group's values, whose writes run the
apply step.
]]

local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("koassistant_gettext")
local logger = require("koassistant_logger")

local GroupSettings = {}

local function groups() return require("koassistant_book_groups") end
local function bookStore() return require("koassistant_book_store") end
local function bookSettings() return require("koassistant_book_settings") end
local function displayName(group)
    return require("koassistant_book_groups_ui").displayName(group)
end

-- ---------------------------------------------------------------- keys + labels
--- Wave-1 keys in screen order.
function GroupSettings.keys()
    local BS = bookSettings()
    return {
        BS.KEY_DOMAIN, BS.KEY_RESEARCH, BS.KEY_BACKGROUND, BS.KEY_SPOILER_FREE, BS.KEY_XRAY_AUTO,
        BS.KEY_XRAY_CATEGORIES, BS.KEY_XRAY_DEPTH, BS.KEY_XRAY_TYPE,
        BS.KEY_RESPONSE_LANG, BS.KEY_TRANSLATION_LANG, BS.KEY_DICTIONARY_LANG, BS.KEY_TEXT_LANG,
    }
end

--- Plain name of a setting, for confirms and toasts.
function GroupSettings.keyLabel(key)
    local BS = bookSettings()
    local labels = {
        [BS.KEY_DOMAIN] = _("Domain"),
        [BS.KEY_BACKGROUND] = _("Background"),
        [BS.KEY_SPOILER_FREE] = _("Spoiler protection"),
        [BS.KEY_RESEARCH] = _("Research mode"),
        [BS.KEY_XRAY_AUTO] = _("Automatic X-Ray"),
        [BS.KEY_XRAY_CATEGORIES] = _("New X-Ray categories"),
        [BS.KEY_XRAY_DEPTH] = _("New X-Ray depth"),
        [BS.KEY_XRAY_TYPE] = _("New X-Ray type"),
        [BS.KEY_RESPONSE_LANG] = _("AI response language"),
        [BS.KEY_TRANSLATION_LANG] = _("Translation language"),
        [BS.KEY_DICTIONARY_LANG] = _("Dictionary language"),
        [BS.KEY_TEXT_LANG] = _("Book text language"),
    }
    return labels[key] or key
end

local function domainName(id, features)
    if id == "_none" then return _("None") end
    local DomainLoader = require("domain_loader")
    for _i, d in ipairs(DomainLoader.getSortedDomains(features.custom_domains or {})) do
        if d.id == id then return d.name or d.display_name or id end
    end
    return id
end

--- Short label of a group VALUE for one key ("not set" when nil).
function GroupSettings.valueLabel(key, v, features, facade)
    local BS = bookSettings()
    if key == BS.KEY_BACKGROUND then
        return BS.backgroundRowLabel(facade)
    end
    if v == nil then return _("not set") end
    if key == BS.KEY_DOMAIN then return domainName(v, features or {}) end
    if key == BS.KEY_SPOILER_FREE or key == BS.KEY_RESEARCH then
        return v and _("On") or _("Off")
    end
    if key == BS.KEY_XRAY_AUTO then return v == "on" and _("On") or _("Off") end
    if key == BS.KEY_XRAY_CATEGORIES then
        return BS.xrayCategoriesLabel(v ~= "full" and v or nil)
    end
    if key == BS.KEY_XRAY_DEPTH then return BS.xrayDepthLabel(v) end
    if key == BS.KEY_XRAY_TYPE then return BS.xrayTypeLabel(v) end
    if key == BS.KEY_RESPONSE_LANG or key == BS.KEY_TRANSLATION_LANG
        or key == BS.KEY_DICTIONARY_LANG then
        return require("koassistant_languages").getDisplay(v)
    end
    if key == BS.KEY_TEXT_LANG then return BS.textLanguageLabel(v) end
    return tostring(v)
end

-- ---------------------------------------------------------------- stores
local function storeFor(path)
    return bookStore().settings(path, nil, { no_migrate = true })
end

local function members(group_id)
    local group = groups().byId(group_id)
    return group and group.books or {}
end

local function isOwnMarker(raw, group_id)
    local BookStore = bookStore()
    return BookStore.isMarker(raw) and raw[BookStore.MARKER_FIELD] == group_id
end

--- Number of values the group sets.
function GroupSettings.setCount(group_id)
    local n = 0
    for _k in pairs(groups().settingsOf(group_id)) do n = n + 1 end
    return n
end

--- Members that do not follow the group for at least one of its set keys.
--- @return table { { file, keys = { key, ... } }, ... }
function GroupSettings.outOfSync(group_id)
    local out = {}
    local settings = groups().settingsOf(group_id)
    if next(settings) == nil then return out end
    for _idx, path in ipairs(members(group_id)) do
        local st = storeFor(path)
        if st then
            local keys = {}
            for key in pairs(settings) do
                if not isOwnMarker(st:readRaw(key), group_id) then keys[#keys + 1] = key end
            end
            if #keys > 0 then
                table.sort(keys)
                out[#out + 1] = { file = path, keys = keys }
            end
        end
    end
    return out
end

-- Post-write refresh the pickers' on_commit hooks would have done for a book
local function afterApply(host, keys)
    local plugin = host and host.plugin
    if not plugin then return end
    if plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
    local BS = bookSettings()
    for _idx, key in ipairs(keys) do
        if (key == BS.KEY_SPOILER_FREE or key == BS.KEY_RESEARCH)
            and plugin._scheduleXrayLadderPromotion then
            plugin:_scheduleXrayLadderPromotion()
        elseif key == BS.KEY_XRAY_AUTO and plugin._refreshXrayAutoState then
            plugin:_refreshXrayAutoState()
        end
    end
end

--- Write the group's marker for `keys` into `paths` (nil = every member).
--- @return integer books written
function GroupSettings.apply(group_id, keys, paths, host)
    local BookStore = bookStore()
    paths = paths or members(group_id)
    local written = 0
    BookStore.suppress_marker_hook = true
    for _idx, path in ipairs(paths) do
        local st = storeFor(path)
        if st then
            for _k, key in ipairs(keys) do
                st:saveSetting(key, BookStore.marker(group_id))
            end
            written = written + 1
        end
    end
    BookStore.suppress_marker_hook = false
    logger.info("KOAssistant GroupSettings: applied", #keys, "setting(s) of", group_id, "to", written, "book(s)")
    afterApply(host, keys)
    return written
end

--- Turn this group's markers into follow-global on `paths` (nil = every
--- member), for `keys` (nil = every per-book key).
function GroupSettings.clearMarkers(group_id, paths, keys, host)
    local BookStore = bookStore()
    paths = paths or members(group_id)
    keys = keys or bookSettings().SIDECAR_KEYS
    local cleared = 0
    BookStore.suppress_marker_hook = true
    for _idx, path in ipairs(paths) do
        local st = storeFor(path)
        if st then
            for _k, key in ipairs(keys) do
                if isOwnMarker(st:readRaw(key), group_id) then
                    st:delSetting(key)
                    cleared = cleared + 1
                end
            end
        end
    end
    BookStore.suppress_marker_hook = false
    if cleared > 0 then
        logger.info("KOAssistant GroupSettings: cleared", cleared, "marker(s) of", group_id)
        afterApply(host, keys)
    end
    return cleared
end

--- A book left the group: its markers for that group become follow-global.
function GroupSettings.onLeave(group_id, path)
    GroupSettings.clearMarkers(group_id, { path })
end

--- The group is gone: every former member's markers for it become follow-global.
function GroupSettings.onRemoved(group_id, books)
    GroupSettings.clearMarkers(group_id, books)
end

--- The toast text when a book's own pick replaces a follow-group marker;
--- nil when the group no longer exists (a stale marker: nothing to say).
function GroupSettings.replacedNotice(key, group_id)
    local group = groups().byId(group_id)
    if not group then return nil end
    return T(_("%1: this book no longer follows the group %2."), GroupSettings.keyLabel(key), displayName(group))
end

-- ---------------------------------------------------------------- apply confirm
-- A value was set at the group: offer to write the marker into every member.
-- Deferred a tick so it lands ABOVE the surface the picker reopens.
local function offerApply(group_id, key, host)
    local paths = members(group_id)
    if #paths == 0 then return end
    local own = 0
    for _idx, path in ipairs(paths) do
        local st = storeFor(path)
        local raw = st and st:readRaw(key)
        if raw ~= nil and not isOwnMarker(raw, group_id) then own = own + 1 end
    end
    local group = groups().byId(group_id)
    local name = group and displayName(group) or ""
    local text = T(_("Apply %1 to all %2 books in %3?"), GroupSettings.keyLabel(key), #paths, name)
    if own > 0 then
        text = text .. "\n" .. T(_("%1 of them have their own value, which this replaces."), own)
    end
    UIManager:nextTick(function()
        UIManager:show(require("ui/widget/confirmbox"):new{
            text = text,
            ok_text = _("Apply"),
            cancel_text = _("Not now"),
            ok_callback = function()
                local n = GroupSettings.apply(group_id, { key }, nil, host)
                UIManager:show(require("ui/widget/notification"):new{
                    text = T(_("Applied to %1 book(s)."), n),
                })
                if host and host.refresh then host.refresh() end
            end,
        })
    end)
end

--- The doc_settings-shaped object the shared pickers edit for a GROUP.
--- host = { plugin, ui, refresh } (refresh = re-read the host screen after an apply).
function GroupSettings.facade(group_id, host)
    local f = { _koa_group_facade = true, group_id = group_id }
    function f:readSetting(key, default)
        local v = groups().getSetting(group_id, key)
        if v == nil then return default end
        return v
    end
    f.readRaw = f.readSetting
    function f:has(key) return groups().getSetting(group_id, key) ~= nil end
    function f:saveSetting(key, value)
        if value == nil then return self:delSetting(key) end
        groups().setSetting(group_id, key, value)
        logger.dbg("KOAssistant GroupSettings: set", group_id, key)
        offerApply(group_id, key, host)
        return self
    end
    function f:delSetting(key)
        groups().setSetting(group_id, key, nil)
        -- Followers of a cleared value are follow-global now: say so on the
        -- book side too, instead of leaving a marker that reads as nothing
        GroupSettings.clearMarkers(group_id, nil, { key }, host)
        return self
    end
    function f:flush() return self end
    function f:isTrue(key) return self:readSetting(key) == true end
    function f:isFalse(key) return self:readSetting(key) == false end
    function f:nilOrTrue(key) local v = self:readSetting(key); return v == nil or v == true end
    function f:nilOrFalse(key) local v = self:readSetting(key); return v == nil or v == false end
    return f
end

function GroupSettings.isFacade(obj)
    return type(obj) == "table" and obj._koa_group_facade == true
end

-- ---------------------------------------------------------------- join ask
--- Books were added to a group that sets values: ask once for the batch.
--- done() runs either way.
function GroupSettings.offerJoin(group_id, paths, host, done)
    local settings = groups().settingsOf(group_id)
    if #paths == 0 or next(settings) == nil then
        if done then done() end
        return
    end
    local keys, labels = {}, {}
    for key in pairs(settings) do keys[#keys + 1] = key end
    table.sort(keys)
    for _idx, key in ipairs(keys) do labels[#labels + 1] = GroupSettings.keyLabel(key) end
    local group = groups().byId(group_id)
    local name = group and displayName(group) or ""
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = T(_("The group %1 sets: %2.\nApply these to the %3 added book(s)? Their own values for these settings would be replaced."),
            name, table.concat(labels, ", "), #paths),
        ok_text = _("Apply"),
        cancel_text = _("Keep their own"),
        ok_callback = function()
            GroupSettings.apply(group_id, keys, paths, host)
            if done then done() end
        end,
        cancel_callback = function() if done then done() end end,
    })
end

-- ---------------------------------------------------------------- the screen
--- opts: { group_id, plugin, ui, on_close }
function GroupSettings.show(opts)
    opts = opts or {}
    local group_id = opts.group_id
    local BookGroups = groups()
    local group = BookGroups.byId(group_id)
    if not group then
        if opts.on_close then opts.on_close() end
        return
    end
    local BS = bookSettings()
    local ButtonDialog = require("ui/widget/buttondialog")
    local plugin, ui = opts.plugin, opts.ui
    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function reopen()
        closeDialog()
        GroupSettings.show(opts)
    end
    local host = { plugin = plugin, ui = ui, refresh = reopen }
    local facade = GroupSettings.facade(group_id, host)
    local function picker(show_fn, extra)
        return function()
            closeDialog()
            local popts = {
                plugin = plugin, ui = ui, doc_settings = facade, scope = "group",
                target_override = "book", target = "book", on_close = reopen,
            }
            for k, v in pairs(extra or {}) do popts[k] = v end
            show_fn(popts)
        end
    end
    local function value(key)
        return GroupSettings.valueLabel(key, facade:readSetting(key), features, facade)
    end

    local rows = {}
    local function row(text, fn) rows[#rows + 1] = {{ text = text, align = "left", callback = fn }} end
    row(T(_("Domain: %1"), value(BS.KEY_DOMAIN)), picker(BS.showDomainResearch))
    -- Research shares the domain picker (its lower section), as in Book Settings
    row(T(_("Research mode: %1"), value(BS.KEY_RESEARCH)), picker(BS.showDomainResearch))
    row(T(_("Background: %1"), value(BS.KEY_BACKGROUND)), picker(BS.showBackgroundEditor))
    row(T(_("Spoiler protection: %1"), value(BS.KEY_SPOILER_FREE)), picker(BS.showSpoilerFree))
    row(T(_("Automatic X-Ray: %1"), value(BS.KEY_XRAY_AUTO)),
        picker(BS.showXrayAutoPicker, { on_change = reopen, on_cancel = reopen }))
    row(T(_("New X-Ray categories: %1"), value(BS.KEY_XRAY_CATEGORIES)), picker(BS.showXrayCategoriesPicker))
    row(T(_("New X-Ray depth: %1"), value(BS.KEY_XRAY_DEPTH)), picker(BS.showXrayDepthPicker))
    row(T(_("New X-Ray type: %1"), value(BS.KEY_XRAY_TYPE)), picker(BS.showXrayTypePicker))
    local langs = 0
    for _idx, key in ipairs({ BS.KEY_RESPONSE_LANG, BS.KEY_TRANSLATION_LANG, BS.KEY_DICTIONARY_LANG, BS.KEY_TEXT_LANG }) do
        if facade:has(key) then langs = langs + 1 end
    end
    row(langs > 0 and T(_("Languages (%1 set) ▸"), langs) or _("Languages ▸"), picker(BS.showLanguageConfig))

    local n_set = GroupSettings.setCount(group_id)
    local out = GroupSettings.outOfSync(group_id)
    if #out > 0 then
        local names = {}
        for i, e in ipairs(out) do
            if i <= 3 then names[#names + 1] = BookGroups.shortName(BookGroups.displayTitle(e.file, ui), 30) end
        end
        local who = table.concat(names, ", ")
        if #out > 3 then who = T(_("%1 +%2"), who, #out - 3) end
        row(T(_("Re-apply to all (%1 not following: %2)"), #out, who), function()
            UIManager:show(require("ui/widget/confirmbox"):new{
                text = T(_("Write every group setting into all %1 books? Their own values for these settings are replaced."), #group.books),
                ok_text = _("Apply"),
                ok_callback = function()
                    local keys = {}
                    for key in pairs(BookGroups.settingsOf(group_id)) do keys[#keys + 1] = key end
                    table.sort(keys)
                    local n = GroupSettings.apply(group_id, keys, nil, host)
                    UIManager:show(require("ui/widget/notification"):new{
                        text = T(_("Applied to %1 book(s)."), n),
                    })
                    reopen()
                end,
            })
        end)
    end
    if n_set > 0 then
        row(_("Clear all group settings…"), function()
            UIManager:show(require("ui/widget/confirmbox"):new{
                text = _("Clear every setting this group sets? Books that follow the group go back to following the global settings."),
                ok_text = _("Clear"),
                ok_callback = function()
                    local keys = {}
                    for key in pairs(BookGroups.settingsOf(group_id)) do keys[#keys + 1] = key end
                    for _idx, key in ipairs(keys) do BookGroups.setSetting(group_id, key, nil) end
                    GroupSettings.clearMarkers(group_id, nil, keys, host)
                    reopen()
                end,
            })
        end)
    end
    rows[#rows + 1] = {{ text = _("Close"), id = "close", callback = function()
        closeDialog()
        if opts.on_close then opts.on_close() end
    end }}

    local title = T(_("%1: group settings"), displayName(group))
    if #group.books == 0 then
        title = title .. "\n" .. _("No books in the group yet. Values set here apply to books as they join.")
    else
        title = title .. "\n" .. T(_("Applies to the %1 books in the group. A book that picks its own value stops following the group for that setting."), #group.books)
    end
    dialog = ButtonDialog:new{
        title = title,
        buttons = rows,
        tap_close_callback = function() dialog = nil; if opts.on_close then opts.on_close() end end,
    }
    UIManager:show(dialog)
end

--- Hub row text: "Group Settings" with the set count and the sync state.
function GroupSettings.rowLabel(group_id)
    local n = GroupSettings.setCount(group_id)
    if n == 0 then return _("Group Settings") end
    local out = #GroupSettings.outOfSync(group_id)
    if out > 0 then return T(_("Group Settings (%1 set, %2 books not following)"), n, out) end
    return T(_("Group Settings (%1 set)"), n)
end

return GroupSettings
