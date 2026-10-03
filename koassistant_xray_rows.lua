--[[--
Shared X-Ray version rows (release_prep A2, 2026-08-11).

The update / instant-install / switch-complete / switch-back / all-versions
rows and the delete-with-versions choice each existed TWICE — main.lua's
X-Ray action popup and the X-Ray browser hamburger — and had drifted: the
hamburger lacked the free instant-install row (its update confirm
cross-referenced "in the X-Ray popup" for a row it didn't have), offered
switch-back under the FULL posture (50(f) hides it there — promotion
re-installs the newest rung on the next turn), never demoted the paid update
beside a free competitor (round 24: free never sits beside paid), and its
delete choice named the prepared-checkpoint cost while the cache viewer's
didn't. ONE builder now owns gates, labels and confirms; the surfaces only
place the rows.

The builder reads disk truth (ladder, ring counts, posture) itself and
re-reads the ladder at confirm time (disk may have moved between drawing a
row and tapping it). Callers pass the live entry their surface renders plus
surface glue: `pre` closes the surface chrome, `retire` retires the host
view before an operation replaces its data (nil when the host closed
already, as in the action popup).
]]

local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("koassistant_gettext")

local XrayRows = {}

--- Version-row bundle for a live main X-Ray surface.
--- ctx:
---   plugin (required)  AskGPT instance — owns every operation fired here
---   file (required)    the book
---   entry (required)   the live main X-Ray entry the surface renders
---   current_progress   {decimal, formatted}; dropped unless `file` is the
---                      plugin's open book (a mismatched position must never
---                      gate another book's rows)
---   on_update          paid-update trigger; the paid row renders only when set
---   action             the xray action for the requirements pre-flight
---                      (fetched from the registry when absent)
---   action_name        paid-row label subject (default "X-Ray")
---   list_opts          opts for the switch/list plugin calls
---                      ({file, book_title, book_author})
---   checkpoint_list_opts  override for the All-versions row (surfaces with a
---                      deferred close_browser hook)
---   pre                fn: close the surface chrome (dialog / options popup)
---   retire             fn|nil: retire the host view before data-replacing ops
---   align              "left" on list-style surfaces
--- @return table { update, instant, switch_complete, switch_back,
---   install_ahead, all_versions, promotable, next_ahead } — each row a ButtonDialog row
function XrayRows.versionRows(ctx)
    local out = {}
    local plugin, file, entry = ctx.plugin, ctx.file, ctx.entry
    if not (plugin and file and entry) then return out end
    local ActionCache = require("koassistant_action_cache")
    local XrayAuto = require("koassistant_xray_auto")
    local pre = ctx.pre or function() end
    local retire = ctx.retire
    local list_opts = ctx.list_opts
    local cached_dec = tonumber(entry.progress_decimal) or 0

    local open_here = plugin.ui and plugin.ui.document
        and plugin.ui.document.file == file
    local cur = open_here and ctx.current_progress or nil

    local ladder_rungs = ActionCache.getXrayLadder(file)
    local ladder_building = XrayAuto.ladderBuild() ~= nil
    local in_flight_here = XrayAuto.isInFlight() and XrayAuto.inFlightFile() == file

    -- Posture + hold (50(f) / promotion-hold round 5): only ever consulted for
    -- the open book — _xrayPosture reads the open book's settings
    local posture = plugin._xrayPosture and plugin:_xrayPosture() or "track"
    local hold = false
    if posture == "full" and open_here and plugin.ui.doc_settings then
        hold = require("koassistant_book_settings").xrayPromotionHold(plugin.ui.doc_settings)
    end

    -- Ladder awareness (popup round 12, now shared): promotable = a prepared
    -- version installable now; next_ahead = the nearest prepared version past
    -- the reader AND past live coverage (a rung the live X-Ray already covers
    -- is not "waiting to install")
    local promotable
    if not ladder_building and cur and not entry.full_document
        and entry.source_mode ~= "ai_knowledge" then
        promotable = XrayAuto.pickPromotableRung(ladder_rungs, cached_dec, cur.decimal,
            (posture == "full" and not hold) and { ahead_ok = true } or nil)
    end
    local next_ahead
    if cur then
        for _idx, r in ipairs(ladder_rungs) do
            local p = tonumber(r.progress_decimal)
            if p and not r.full_document and p > cur.decimal + 0.005
                and p > cached_dec + 0.005 then
                if not next_ahead or p < next_ahead then next_ahead = p end
            end
        end
    end
    out.promotable, out.next_ahead = promotable, next_ahead

    local function row(text, callback)
        return {{ text = text, align = ctx.align, callback = callback }}
    end

    -- Paid to-position update (round 14: always confirms; round 24: DROPPED
    -- entirely when a free competitor is ready or lands within a spacing —
    -- the creation chooser's extend mode keeps the paid path reachable)
    local update_case = ctx.on_update and cur and not entry.full_document
        and cur.decimal > cached_dec + 0.01
    local spacing = XrayAuto.LADDER_SPACING
    if open_here and not (plugin.ui.document.info and plugin.ui.document.info.has_pages) then
        -- Spacing slice: the demote window honors the per-book override too
        spacing = plugin._xrayLadderSpacing and plugin:_xrayLadderSpacing()
            or XrayAuto.ladderSpacingFor(plugin.ui.document:getPageCount())
    end
    local demote_paid = update_case and (promotable ~= nil
        or (next_ahead ~= nil and next_ahead - cur.decimal <= spacing + 0.005))
    if update_case and not demote_paid and not ladder_building and not in_flight_here then
        out.update = row(T(_("Update %1 (to %2)"), ctx.action_name or _("X-Ray"), cur.formatted),
            function()
                pre()
                local act = ctx.action
                if not act and plugin.action_service then
                    act = plugin.action_service:getAction("book", "xray")
                end
                -- A run option's model (B345) is the provider the update reaches
                local rv = ctx.list_opts and ctx.list_opts.run_variant
                if act and plugin._checkRequirements
                        and plugin:_checkRequirements(act, nil, rv and rv.provider or nil) then
                    return
                end
                -- Mid-ladder honesty lines, recomputed from disk at tap time
                local confirm_text = T(_("Update the X-Ray to exactly %1 with one API call?"),
                    cur.formatted)
                local rungs_now = ActionCache.getXrayLadder(file)
                if (ActionCache.highestXrayLadderProgress(rungs_now) or 0) > cached_dec + 0.005 then
                    confirm_text = confirm_text .. "\n"
                        .. _("Checkpoints are not touched: they still swap in for free as you read past them.")
                    local c_next, c_avail
                    for _idx, r in ipairs(rungs_now) do
                        local p = tonumber(r.progress_decimal)
                        if p and not r.full_document then
                            if p > cur.decimal + 0.005 then
                                if not c_next or p < c_next then c_next = p end
                            elseif p > cached_dec + 0.005 then
                                if not c_avail or p > c_avail then c_avail = p end
                            end
                        end
                    end
                    if c_avail then
                        confirm_text = confirm_text .. "\n" .. T(_("A free checkpoint at %1% is available right now (\"Update to %1%, instant\")."),
                            math.floor(c_avail * 100 + 0.5))
                    elseif c_next then
                        confirm_text = confirm_text .. "\n" .. T(_("The next free checkpoint arrives at %1%."),
                            math.floor(c_next * 100 + 0.5))
                    end
                end
                -- Background updates are flowing-only (_fireXrayAutoUpdate
                -- bails on has_pages) — never offer a button that would
                -- silently no-op on page-based books
                local bg_ok = plugin.ui and plugin.ui.document
                    and plugin.ui.document.file == file
                    and not (plugin.ui.document.info and plugin.ui.document.info.has_pages)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = confirm_text,
                    ok_text = _("Update"),
                    ok_callback = function()
                        if retire then retire() end
                        ctx.on_update()
                    end,
                    other_buttons = bg_ok and {{{
                        text = _("Update in background (keep reading)"),
                        callback = function()
                            if retire then retire() end
                            -- a run option from the popup (B345) rides along
                            plugin:_fireXrayAutoUpdate({ manual = true,
                                run_variant = ctx.list_opts and ctx.list_opts.run_variant })
                        end,
                    }}} or nil,
                })
            end)
    end

    -- Free local install from a prepared version (§6 slice 1)
    if promotable then
        out.instant = row(T(_("Update to %1%, instant"),
            math.floor((tonumber(promotable.progress_decimal) or 0) * 100 + 0.5)),
            function()
                pre()
                if plugin:_fireXrayLadderPromotion({ manual = true }) then
                    if retire then retire() end
                    -- Dedup ask fires inside the promotion itself now (filing
                    -- 08-17 §14: every install into live runs the pair-check)
                else
                    -- Disk moved between drawing the row and tapping it
                    UIManager:show(require("ui/widget/infomessage"):new{
                        text = _("Nothing to update from checkpoints: the X-Ray moved in the meantime."),
                        timeout = 3,
                    })
                end
            end)
    end

    -- Free switch to a finished 1.0 rung — never over a complete cache or a
    -- foreign lineage
    local ladder_highest = ActionCache.highestXrayLadderProgress(ladder_rungs)
    local cache_complete = entry.full_document or cached_dec >= 0.995
    if not cache_complete and (ladder_highest or 0) >= 0.995
        and entry.source_mode ~= "ai_knowledge" then
        out.switch_complete = row(_("Switch to complete version (100%), instant"),
            function()
                pre()
                if retire then retire() end
                plugin:_switchToCompleteXrayRung(list_opts)
            end)
    end

    -- Free exit from ahead-mode. 50(f): hidden under the FULL posture (unless
    -- the promotion hold pins the book) — promotion would re-install the
    -- newest rung on the next turn. COMPLETE installs offer it too since the
    -- 2026-08-13 device round (the old "Item 40: gone once complete" rule
    -- left no one-tap way back to position-following with a complete version
    -- pinned under spoiler protection; the switch sets the promotion hold,
    -- so it sticks — deliberate installs still never auto-revert).
    local cached_eff = entry.full_document and 1.0 or cached_dec
    if cur and (posture ~= "full" or hold)
        and entry.source_mode ~= "ai_knowledge"
        and cached_eff > cur.decimal + 0.01 then
        local back_rung = XrayAuto.pickPromotableRung(ladder_rungs, 0, cur.decimal)
        if back_rung then
            out.switch_back = row(T(_("Switch back to your position (%1%), instant"),
                math.floor((tonumber(back_rung.progress_decimal) or 0) * 100 + 0.5)),
                function()
                    pre()
                    if retire then retire() end
                    plugin:_switchBackToPositionRung(list_opts)
                end)
        end
    end

    -- One-tap install of the built-ahead rung (spacing slice; was All-versions
    -- only). Deliberate spoiler-side pick, so only where promotion would NOT
    -- install it by itself anyway (track posture, or full pinned by the hold);
    -- never during a build/flight (the card blocks that too — race/clobber).
    if next_ahead and (posture ~= "full" or hold)
        and not ladder_building and not in_flight_here
        and plugin._installAheadXrayRung
        and entry.source_mode ~= "ai_knowledge" then
        out.install_ahead = row(T(_("Install checkpoint to %1% (ahead), instant"),
            math.floor(next_ahead * 100 + 0.5)),
            function()
                pre()
                if retire then retire() end
                plugin:_installAheadXrayRung(list_opts)
            end)
    end

    -- All versions (ring + ladder; O(1) header counts — a menu row must not
    -- full-parse rings)
    local total = ActionCache.getXrayCheckpointCount(file)
        + ActionCache.getXrayLadderCount(file)
    if total > 0 then
        out.all_versions = row(T(_("All versions (%1)…"), total),
            function()
                pre()
                plugin:_showXrayCheckpointList(ctx.checkpoint_list_opts or list_opts)
            end)
    end

    return out
end

--- Delete-with-versions choice content — ONE source for the browser
--- hamburger's delete and the cache viewer's delete_options/delete_title
--- (the viewer previously omitted the prepared-checkpoints line).
--- @param file string
--- @return table|nil nil = plain confirm (no versions in play);
---   { two_way = true, title, keep_text, drop_text, n_arch, n_prep } when the
---   ring has entries (round 28: the reader picks whether archives survive);
---   { two_way = false, title, n_prep } when only prepared checkpoints exist
---   (they die with the X-Ray either way — resurrection guard)
function XrayRows.deleteChoice(file)
    if not file then return nil end
    local ActionCache = require("koassistant_action_cache")
    local n_arch = ActionCache.getXrayCheckpointCount(file)
    local n_prep = ActionCache.getXrayLadderCount(file)
    if n_arch > 0 then
        -- P5 (maintainer 2026-08-16): delete-keeping-versions IS archiving, so
        -- name it that. The entry row stays "Delete X-Ray" (it is still the
        -- delete entry); the choice inside offers Archive vs full delete.
        local title = T(_("Archive or delete this X-Ray? Archiving removes the live X-Ray but keeps its %1 saved versions reachable under \"Archived X-Ray Versions\" in View Artifacts."), n_arch)
        if n_prep > 0 then
            title = title .. "\n" .. T(_("Its %1 prepared checkpoints are deleted either way."), n_prep)
        end
        return { two_way = true, title = title, n_arch = n_arch, n_prep = n_prep,
            keep_text = T(_("Archive X-Ray (keep %1 versions)"), n_arch),
            drop_text = T(_("Delete X-Ray and %1 versions"), n_arch) }
    end
    if n_prep > 0 then
        return { two_way = false, n_arch = 0, n_prep = n_prep,
            title = T(_("Delete this X-Ray? Its %1 checkpoints are deleted with it. This cannot be undone."), n_prep) }
    end
    return nil
end

--- The group's row label and its dialog title (B401).
function XrayRows.linkMergeLabel() return _("Link and merge…") end
function XrayRows.linkMergeTitle() return _("Link and merge") end

--- The "Link and merge…" group of a live main X-Ray (B401), for the X-Ray
--- action popup AND the X-Ray browser's menu: ONE copy of the rows, their
--- order, labels and gates, so the two surfaces cannot drift (the browser's
--- menu listed these rows flat and in another order until 2026-10-03). The
--- carried list leads: it is where a reader links names by hand, free. The
--- paid rows follow, each starting with "AI merge" and, between books, ending
--- with its request count. The duplicate review closes.
--- ctx:
---   plugin (required)  AskGPT instance (the group merge's kind)
---   file (required)    the book
---   carried_count      the carried entries the surface counts itself (the
---                      browser holds the parsed X-Ray); when absent the
---                      count is read from disk, and `raw` (the X-Ray's text,
---                      when the surface holds it) skips that read for a
---                      text without a carried list
---   section_count      this book's section X-Rays
---   pre                fn: close the surface chrome
---   align              "left" on list-style surfaces
---   on_carried, on_cross_book, on_group_merge(kind), on_sections, on_dedup
---                      what each row starts on this surface; a missing
---                      handler drops its row
--- @return table rows ButtonDialog rows, in display order
function XrayRows.linkMergeRows(ctx)
    local rows = {}
    local plugin, file = ctx.plugin, ctx.file
    if not (plugin and file) then return rows end
    local pre = ctx.pre or function() end
    local function add(text, handler, arg)
        if not handler then return end
        rows[#rows + 1] = {{
            text = text, align = ctx.align,
            callback = function()
                pre()
                handler(arg)
            end,
        }}
    end

    local Browser = require("koassistant_xray_browser")
    local carried_label
    if ctx.carried_count then
        carried_label = ctx.carried_count > 0
            and Browser.carriedListTitle(file, ctx.carried_count) or nil
    else
        carried_label = Browser.carriedListLabel(file, ctx.raw)
    end
    if carried_label then add(carried_label .. "…", ctx.on_carried) end

    add(_("AI merge with another book (1 request)…"), ctx.on_cross_book)
    local kind = plugin._groupXrayMergeKind and plugin:_groupXrayMergeKind(file)
    if kind then
        add(kind == "project" and _("AI merge the group into this book (1 request per book)…")
            or _("AI merge the series (1 request per book)…"), ctx.on_group_merge, kind)
    end
    if (tonumber(ctx.section_count) or 0) > 0 then
        add(T(_("AI merge section X-Rays (%1)…"), ctx.section_count), ctx.on_sections)
    end
    add(_("Find duplicate entities…"), ctx.on_dedup)
    return rows
end

return XrayRows
