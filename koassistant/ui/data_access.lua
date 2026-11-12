--[[
The question before a kind of the reader's data goes out for the first time,
and the funnel that asks it (docs/data_access_picture.md sections 4.4 and 4.6,
B395 slice 2).

One dialog, built once, used everywhere:

    Explain in Context will send to OpenAI:
    • text from this book, up to your position (42%)
    • your highlights (12)

    [ Allow once ]  [ Allow for this book ]
    [ Not for this book ]            (only when nothing asked is required)
    [ More… ]  [ Cancel ]

One question per run, listing every kind still on Ask. Allow once covers the
run and that chat's replies (Gates.grantOnce on the request's config copy,
never stored). Allow for this book writes the book's own value; Not for this
book writes Never for the optional kinds asked (the run goes on without them).
The two kinds no book can hold (the book list, reading habits) get Always
allow instead, which writes the global value. More… opens the book's Privacy
screen (or the settings) and asks again when it closes. A required kind on
Never is a refusal that names the layer, with one button to the same screen.

koassistant/request/privacy_gates.lua decides the states; this module only
asks and applies the answer. koassistant/ui/dialogs.lua's dispatch entry calls
`withAccess` before anything is read or sent; the surfaces that ask earlier
(the source popup's Run, the Scope and Tools chips, the attachments, the
X-Ray chat, the library Send, the X-Ray builds) call it with what they know.
]]

local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local Gates = require("koassistant.request.privacy_gates")
local logger = require("koassistant.core.logger")
local _ = require("koassistant.core.gettext")
local T = require("ffi/util").template

local DataAccess = {}

--- The plain words for a kind, as the question lists it.
function DataAccess.kindLabel(kind)
    if kind == "book_text" then return _("text from this book") end
    if kind == "highlights" then return _("your highlights") end
    if kind == "annotations" then return _("your notes on highlights") end
    if kind == "notebook" then return _("your notebook") end
    if kind == "position" then return _("your reading position") end
    if kind == "habits" then return _("your reading habits") end
    if kind == "book_list" then return _("your library scan") end
    if kind == "nearby_text" then return _("the text around what you tapped") end
    return tostring(kind)
end

--- The kind as a setting's name (the refusal, the screens).
function DataAccess.kindName(kind)
    if kind == "book_text" then return _("Book text") end
    if kind == "highlights" then return _("Highlights") end
    if kind == "annotations" then return _("Annotation notes") end
    if kind == "notebook" then return _("Notebook") end
    if kind == "position" then return _("Reading position") end
    if kind == "habits" then return _("Reading habits") end
    if kind == "book_list" then return _("Library Scan") end
    if kind == "nearby_text" then return _("Text around what you tap") end
    return tostring(kind)
end

--- Where a value comes from, in words.
function DataAccess.layerLabel(layer)
    if layer == "book" then return _("this book") end
    if layer == "trusted" then return _("trusted providers") end
    if layer == "once" then return _("this run") end
    return _("all books")
end

--- A privacy preset's name (B499): "default" | "full" | "minimal", nil = Custom.
function DataAccess.presetLabel(preset)
    if preset == "default" then return _("Default (Ask)") end
    if preset == "full" then return _("Allow everything") end
    if preset == "minimal" then return _("Block everything") end
    return _("Custom")
end

--- Pure: what a list of needs (Gates.needs) means for the dialog.
--- @return table { asked = { need, ... } (state ask, KINDS order), refused = need|nil
---   (the first required kind on Never), optional_only = boolean (nothing asked
---   is required), per_book = boolean (some asked kind can be stored for a book),
---   global_only = boolean (every asked kind is one no book can hold) }
function DataAccess.plan(needs)
    local out = { asked = {}, optional_only = true, per_book = false, global_only = true }
    for _idx, n in ipairs(needs or {}) do
        if n.state == "never" and n.required and not out.refused then
            out.refused = n
        elseif n.state == "ask" then
            out.asked[#out.asked + 1] = n
            if n.required then out.optional_only = false end
            if Gates.BOOK_KINDS[n.kind] then out.per_book = true; out.global_only = false end
        end
    end
    return out
end

--- Pure: the question's text. spec.action_name, spec.provider_name,
--- spec.amounts = { kind = line } (a line per kind, else the plain label),
--- spec.asked = the plan's list, spec.note = an extra sentence (the spoiler
--- reach, the books left out), spec.optional_only.
function DataAccess.questionText(spec)
    local lines = {}
    lines[#lines + 1] = T(_("%1 will send to %2:"), spec.action_name or _("This action"),
        spec.provider_name or _("your AI provider"))
    -- the reading habits are read from the library scan's books ("for those
    -- books"): listed right after it, the line that names the folders
    local listed, habits = {}, nil
    for _idx, n in ipairs(spec.asked or {}) do
        if n.kind == "habits" then habits = n else listed[#listed + 1] = n end
    end
    if habits then
        local at = #listed + 1
        for i, n in ipairs(listed) do
            if n.kind == "book_list" then at = i + 1 end
        end
        table.insert(listed, at, habits)
    end
    for _idx, n in ipairs(listed) do
        local line = spec.amounts and spec.amounts[n.kind] or DataAccess.kindLabel(n.kind)
        lines[#lines + 1] = "• " .. line
    end
    if spec.note and spec.note ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = spec.note
    end
    return table.concat(lines, "\n")
end

--- Show the question. on_answer(choice): "once" | "once_without" | "book" |
--- "not_book" | "without" | "always" | "more" | "cancel". spec: the questionText fields
--- plus spec.plan (DataAccess.plan), spec.set (a request over many books:
--- Allow once and Cancel only), spec.standing_only (no Allow once: a feature
--- with no moment to ask offers Allow for this book alone), spec.decline_once
--- (Continue without in place of Not for this book: the run goes on without
--- the optional kinds and nothing is stored; the image run, whose kinds reach
--- it indirectly, where a book-wide Never would stop the book's X-Ray updates),
--- spec.no_book (no book to hold a value: no Allow for this book, no Not for
--- this book). The folder window (round 2, 2026-10-20; built by withAccess):
--- spec.folders = { rows = { { path, ticked } }, toggle(i), add(replace) },
--- one row per folder above the answers; spec.run_only = nothing on Ask
--- (Run and Cancel, answer "run"); spec.without_only = nothing to send and
--- nothing required (Continue without and Cancel); spec.blocked = the run
--- needs a folder ticked: its answers are shown disabled.
function DataAccess.ask(plugin, spec, on_answer)
    local dialog
    local answered = false
    local function answer(choice)
        if answered then return end
        answered = true
        if dialog then UIManager:close(dialog) end
        local kinds = {}
        for _idx, need in ipairs((spec.plan and spec.plan.asked) or spec.asked or {}) do kinds[#kinds + 1] = need.kind end
        logger.dbg("KOAssistant data access: asked", table.concat(kinds, ","), "for", spec.action_name or "?", "answer", choice)
        on_answer(choice)
    end
    local plan = spec.plan or { asked = spec.asked or {}, optional_only = false, per_book = true }
    -- The asked kinds the run can go without (the optional ones), named on
    -- the button of a run that also asks a required kind
    local optional_labels = {}
    for _idx, n in ipairs(plan.asked or {}) do
        if not n.required then optional_labels[#optional_labels + 1] = DataAccess.kindLabel(n.kind) end
    end
    -- A set of books holds no per-book answer; the kinds no book holds (the
    -- book list, reading habits) keep Always allow and More… in a set too
    local set_global = spec.set and plan.global_only
    local rows = {}
    -- The folder window: the scan folders this run reads, ticked or not; a
    -- tap ticks or unticks one (the window is drawn again), "+ Add folder…"
    -- picks another for this run
    if spec.folders then
        for i, row in ipairs(spec.folders.rows) do
            rows[#rows + 1] = { {
                text = (row.ticked and "\u{2611} " or "\u{2610} ") .. DataAccess.folderNames({ row.path }),
                callback = function()
                    answered = true  -- replaced by the window drawn again, not answered
                    UIManager:close(dialog)
                    spec.folders.toggle(i)
                end,
                hold_callback = function()
                    UIManager:show(InfoMessage:new{ text = row.path, timeout = 5 })
                end,
            } }
        end
        rows[#rows + 1] = { { text = _("+ Add folder…"), callback = function()
            spec.folders.add(function()
                answered = true
                UIManager:close(dialog)
            end)
        end } }
    end
    local first, skip = {}, {}
    if spec.run_only then
        first[1] = { text = _("Run"), enabled = not spec.blocked, callback = function() answer("run") end }
    elseif spec.without_only then
        skip[1] = { text = _("Continue without"), callback = function() answer("without") end }
    else
        if not spec.standing_only then
            first[#first + 1] = { text = _("Allow once"), callback = function() answer("once") end }
        end
        if not spec.set or set_global then
            if plan.global_only then
                first[#first + 1] = { text = _("Always allow"), callback = function() answer("always") end }
            elseif not spec.no_book then
                first[#first + 1] = { text = _("Allow for this book"), callback = function() answer("book") end }
            end
        end
        -- Going without the optional part, for this run only (2026-10-20): the
        -- whole ask when nothing asked is required, else the required kinds
        -- allowed once and the optional ones left out. Not for this book stays
        -- the lasting choice for a book's own kinds.
        -- (a set asking each book's own data stays Allow once / Cancel: its needs
        -- do not tell a book's required kinds from its optional ones)
        if #optional_labels > 0 and not spec.standing_only and (not spec.set or set_global) then
            if plan.optional_only then
                skip[#skip + 1] = { text = _("Continue without"), callback = function() answer("without") end }
            else
                skip[#skip + 1] = { text = T(_("Allow once, without %1"), table.concat(optional_labels, ", ")),
                    callback = function() answer("once_without") end }
            end
        end
        if not spec.set and plan.optional_only and plan.per_book and not spec.no_book and not spec.decline_once then
            skip[#skip + 1] = { text = _("Not for this book"), callback = function() answer("not_book") end }
        end
        if spec.blocked then
            for _idx, b in ipairs(first) do b.enabled = false end
            for _idx, b in ipairs(skip) do b.enabled = false end
        end
    end
    if #first > 0 then rows[#rows + 1] = first end
    if #skip > 0 then rows[#rows + 1] = skip end
    local last = {}
    if not spec.run_only and (not spec.set or set_global) then
        last[#last + 1] = { text = _("More…"), callback = function() answer("more") end }
    end
    last[#last + 1] = { text = _("Cancel"), id = "close", callback = function() answer("cancel") end }
    rows[#rows + 1] = last
    dialog = ButtonDialog:new{
        title = DataAccess.questionText(spec),
        buttons = rows,
        tap_close_callback = function() answer("cancel") end,
    }
    UIManager:show(dialog)
    return dialog
end

-- The book's own Privacy screen for a path, then `after` when it closes.
local function openBookPrivacy(plugin, path, ui, after)
    require("koassistant.books.book_settings").showPrivacyConfig({
        plugin = plugin, ui = ui, document_path = path, on_close = after,
    })
end

--- The refusal for a required kind on Never: names the layer, one button to
--- the screen that holds the value. spec: kind, layer, action_name, path, ui,
--- hint (the action's blocked_hint).
function DataAccess.refuse(plugin, spec)
    logger.dbg("KOAssistant data access: refused", spec.kind, "layer", spec.layer, "for", spec.action_name or "?")
    local name = DataAccess.kindName(spec.kind)
    local text
    if spec.layer == "book" then
        text = T(_("%1 needs %2, which is set to Never for this book (Book Settings → Privacy & Data)."),
            spec.action_name or _("This action"), name:lower())
    elseif spec.layer == "trusted" then
        text = T(_("%1 needs %2, which is set to Never for trusted providers (Settings → Privacy & Data → What trusted providers may use)."),
            spec.action_name or _("This action"), name:lower())
    else
        text = T(_("%1 needs %2, which is set to Never for all books (Settings → Privacy & Data)."),
            spec.action_name or _("This action"), name:lower())
    end
    if spec.hint and spec.hint ~= "" then text = text .. "\n\n" .. spec.hint end
    local dialog
    local rows = {}
    if spec.layer == "book" and spec.path then
        rows[#rows + 1] = { { text = _("Change for this book…"), callback = function()
            UIManager:close(dialog)
            openBookPrivacy(plugin, spec.path, spec.ui, nil)
        end } }
    elseif plugin and spec.layer == "trusted" and plugin.onKOAssistantSettings then
        -- the trusted providers' column is in the settings menu (Privacy &
        -- Data → What trusted providers may use), not on the screen below
        rows[#rows + 1] = { { text = _("Open Settings"), callback = function()
            UIManager:close(dialog)
            plugin:onKOAssistantSettings()
        end } }
    elseif plugin then
        -- the values for all books: the Privacy & Data screen
        rows[#rows + 1] = { { text = _("Open Settings"), callback = function()
            UIManager:close(dialog)
            require("koassistant.books.book_settings").showPrivacyConfig({
                plugin = plugin, ui = spec.ui, all_books = true,
            })
        end } }
    end
    rows[#rows + 1] = { { text = _("Close"), id = "close", callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{ title = text, buttons = rows }
    UIManager:show(dialog)
end

-- The provider's display name.
local function providerName(plugin, provider)
    if plugin and plugin.getProviderDisplayName and provider then
        local ok, name = pcall(function() return plugin:getProviderDisplayName(provider) end)
        if ok and name then return name end
    end
    return provider or _("your AI provider")
end

-- Write a book's own value for the kinds (true = Allow, false = Never).
local function writeBookValues(path, ui, kinds, value)
    if not path then return false end
    local ok, ds = pcall(function()
        return require("koassistant.storage.doc_settings").resolve(path, ui)
    end)
    if not (ok and ds) then return false end
    local BookSettings = require("koassistant.books.book_settings")
    local wrote = false
    for _idx, kind in ipairs(kinds) do
        local key = BookSettings.PRIVACY_KEY_OF_KIND[kind]
        if key then
            ds:saveSetting(key, value)
            wrote = true
        end
    end
    if wrote then
        ds:flush()
        logger.info("KOAssistant: privacy value written for the book:", value and "allow" or "never", #kinds, "kinds")
    end
    return wrote
end

--- "Allow for this book" from a surface that is its own question (the
--- automatic X-Ray's start confirm): writes the book's value for the kinds.
function DataAccess.allowForBook(path, ui, kinds)
    return writeBookValues(path, ui, kinds, true)
end

-- Always allow, for the kinds no book can hold: the value for all books in
-- the column the question was judged from (a trusted provider's own column
-- when trust picked it), in the settings file AND in the run's own settings
-- table, which may be a copy taken before the question (a Quick Actions or
-- file-browser run): the run passing the question again must find it.
local function writeAlwaysAllow(plugin, asked, run_features)
    if not (plugin and plugin.settings) then return end
    local f = plugin.settings:readSetting("features") or {}
    for _idx, need in ipairs(asked) do
        local key, value = Gates.GLOBAL_KEY[need.kind], true
        if need.layer == "trusted" then key, value = Gates.TRUSTED_KEY[need.kind], "allow" end
        if key then
            f[key] = value
            if type(run_features) == "table" then run_features[key] = value end
        end
    end
    plugin.settings:saveSetting("features", f)
    plugin.settings:flush()
    if plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
    logger.info("KOAssistant: privacy value set to Allow for all books:", #asked, "kinds")
end

-- The values for all books as the settings file holds them now, into a run's
-- own settings table (a copy taken before the question): after More…, the
-- question asked again judges what the reader set on the screen.
local function refreshPrivacyKeys(plugin, features)
    if type(features) ~= "table" or not (plugin and plugin.settings) then return end
    local live = plugin.settings:readSetting("features") or {}
    for _kind, key in pairs(Gates.GLOBAL_KEY) do features[key] = live[key] end
    for _kind, key in pairs(Gates.TRUSTED_KEY) do features[key] = live[key] end
    features.trusted_providers = live.trusted_providers
end

--- The scan folders a run reads, one rule for the question and the gathers
--- (2026-10-20): the run's own pick from the folder window (the allowance's
--- folders, Gates.pickFolders) first; then, for a run started from the
--- library dialog, that dialog's pick (plugin._session_scan_folders, set once
--- a folder is ticked or unticked there); else the permanent folders. An
--- empty pick = no list.
--- @return table list of folder paths (possibly empty)
function DataAccess.scanFolders(plugin, library_run, features)
    local once = type(features) == "table" and features._data_once
    if type(once) == "table" and type(once.folders) == "table" then return once.folders end
    if library_run and plugin and type(plugin._session_scan_folders) == "table" then
        return plugin._session_scan_folders
    end
    local f = plugin and plugin.settings and plugin.settings:readSetting("features") or features or {}
    return type(f.library_scan_folders) == "table" and f.library_scan_folders or {}
end

--- The folders by their own names, for the question: up to three, then "…".
function DataAccess.folderNames(folders)
    local names = {}
    for i, path in ipairs(folders or {}) do
        if i > 3 then names[#names + 1] = "…"; break end
        names[#names + 1] = tostring(path):match("([^/]+)/*$") or tostring(path)
    end
    return table.concat(names, ", ")
end

--- The question's lines for the library scan and the reading habits, naming
--- the folders they come from (nil without a folder: nothing would go).
function DataAccess.libraryAmounts(folders)
    if type(folders) ~= "table" or #folders == 0 then return nil, nil end
    return T(_("your library scan: the books in %1 (titles, authors, reading status)"), DataAccess.folderNames(folders)),
        _("your reading habits for those books (read a lot, stalled, barely started)")
end

--- The same lines in the folder window, whose folders are listed below them.
function DataAccess.windowAmounts()
    return _("your library scan: the books in the folders ticked below (titles, authors, reading status)"),
        _("your reading habits for those books (read a lot, stalled, barely started)")
end

-- Whether a path is a folder now (a remembered one may be gone); without the
-- file system module (the tests) every path counts
local function isDirectory(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (ok and lfs and lfs.attributes) then return true end
    return lfs.attributes(path, "mode") == "directory"
end

local RECENT_FOLDERS_MAX = 5

--- The folders added on the fly (the folder window's and the library
--- dialog's "+ Add folder…"), newest first, those still there: offered again
--- unticked, scanned only when ticked, never made permanent.
function DataAccess.recentFolders(plugin)
    local f = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
    local out = {}
    for _idx, path in ipairs(type(f.library_recent_folders) == "table" and f.library_recent_folders or {}) do
        if type(path) == "string" and path ~= "" and isDirectory(path) then out[#out + 1] = path end
    end
    return out
end

--- Remember a folder added on the fly, first in the list (five kept).
function DataAccess.rememberFolder(plugin, path)
    if not (plugin and plugin.settings) or type(path) ~= "string" or path == "" then return end
    local f = plugin.settings:readSetting("features") or {}
    local list = { path }
    for _idx, p in ipairs(type(f.library_recent_folders) == "table" and f.library_recent_folders or {}) do
        if p ~= path and #list < RECENT_FOLDERS_MAX then list[#list + 1] = p end
    end
    f.library_recent_folders = list
    plugin.settings:saveSetting("features", f)
    plugin.settings:flush()
end

--- Pure: the folder window's rows: the folders the run would read, ticked;
--- then the other permanent folders and the recent ones, unticked (each once).
function DataAccess.folderRows(defaults, permanent, recent)
    local rows, seen = {}, {}
    local function add(path, ticked)
        if type(path) ~= "string" or path == "" or seen[path] then return end
        seen[path] = true
        rows[#rows + 1] = { path = path, ticked = ticked }
    end
    for _idx, p in ipairs(defaults or {}) do add(p, true) end
    for _idx, p in ipairs(permanent or {}) do add(p, false) end
    for _idx, p in ipairs(recent or {}) do add(p, false) end
    return rows
end

--- Pure: the library need that opens the folder window (round 2,
--- 2026-10-20): the run reads the library, Library Scan is not Never, and it
--- is on Ask or the run cannot do without the list. nil = no window (on
--- Allow, a run that only can use the list reads the folders as they are).
function DataAccess.folderWindowNeed(needs)
    for _idx, n in ipairs(needs or {}) do
        if n.kind == "book_list" and n.state ~= "never" and (n.state == "ask" or n.required) then return n end
    end
    return nil
end

--- The needs of a run over several books (a library request with picked
--- books): each book's own values decide for its data; one question for the
--- set. Returns the needs list (per kind, state ask when any book asks) plus
--- the kinds no book holds (the book list, reading habits) as the action
--- declares them, and the count of books on Never.
local function needsForSet(action, opts)
    local kinds = { "book_text", "highlights", "annotations", "notebook" }
    -- what the action reads of each book, or what each book's own stored
    -- material was built from (book.kinds, a merge's set: slice 5)
    local wanted = {}
    if action.use_highlights then wanted.highlights = true end
    if action.use_annotations then wanted.annotations = true; wanted.highlights = true end
    if action.use_notebook then wanted.notebook = true end
    local function bookWants(book, kind)
        if type(book.kinds) == "table" then return book.kinds[kind] == true end
        return wanted[kind] == true
    end
    local out, never_books = {}, 0
    local never_seen = {}
    for _idx, kind in ipairs(kinds) do
        local any_ask = false
        for _b, book in ipairs(opts.books) do
            if bookWants(book, kind) then
                local ctx = Gates.context(opts.features, opts.provider, { path = book.file, ui = opts.ui })
                local state = Gates.resolve(kind, ctx)
                if state == "ask" then any_ask = true end
                if state == "never" and not never_seen[book.file] then
                    never_seen[book.file] = true
                    never_books = never_books + 1
                end
            end
        end
        if any_ask then
            out[#out + 1] = { kind = kind, state = "ask", layer = "global", required = false }
        end
    end
    local ctx = Gates.context(opts.features, opts.provider, {})
    for _idx, n in ipairs(Gates.needs(action, ctx, { source = opts.source, stamps = opts.stamps, exists = opts.exists })) do
        if not Gates.BOOK_KINDS[n.kind] then out[#out + 1] = n end
    end
    return out, never_books
end

-- How strict a state is, for a kind sent to more than one provider
local STATE_RANK = { allow = 0, ask = 1, never = 2 }

--- What a saved result was built with beyond the book's text, for a run that
--- continues it (an update sends the result back with the new text): the
--- kinds as optional entries of an explicit list (needsFor's opts.kinds) and
--- the question's line for each. `name` = the result's name ("X-Ray").
--- @return table kinds, table amounts
function DataAccess.baseKinds(entry, name)
    local kinds, amounts = {}, {}
    local k = type(entry) == "table" and Gates.stampedKinds(entry) or {}
    if k.highlights then
        kinds[#kinds + 1] = { kind = "highlights", required = false }
        amounts.highlights = T(_("the saved %1, which was built with your highlights"), name)
    end
    if k.annotations then
        kinds[#kinds + 1] = { kind = "annotations", required = false }
        amounts.annotations = T(_("the saved %1, which was built with your notes"), name)
    end
    return kinds, amounts
end

--- What a run wants, with each kind's state: the action's declarations for
--- its book (Gates.needs), a set of picked books (needsForSet), or an
--- explicit list of kinds (a pick that is not an action). With opts.kinds,
--- opts.providers lists every provider the data reaches (the image action
--- with its prompt writer: the writer's and the image provider's); a kind's
--- state is the strictest of theirs (Never, then Ask, then Allow).
--- @return table needs, number|nil never_books (sets only)
function DataAccess.needsFor(action, opts)
    action = action or {}
    opts = opts or {}
    if opts.needs then return opts.needs, opts.never_books end
    local features = opts.features or {}
    if opts.books then
        return needsForSet(action, opts)
    end
    local ctx = Gates.context(features, opts.provider, { path = opts.path, ui = opts.ui, book = opts.book })
    if opts.kinds then
        local needs, at = {}, {}
        for _idx, k in ipairs(opts.kinds) do
            -- a kind, or { kind, required } when the list mixes required and
            -- optional kinds (the X-Ray chat: the entry's text, its highlights)
            local kind, req = k, opts.required ~= false
            if type(k) == "table" then kind, req = k.kind, k.required ~= false end
            if at[kind] then
                -- one kind asked twice (a page scope and the text around a
                -- selection): one line, required when either use is, so no
                -- "without" can leave out what an allowance lets through
                if req then needs[at[kind]].required = true end
                goto continue
            end
            local state, layer
            for _p, provider in ipairs(opts.providers or {}) do
                ctx.provider = provider
                local s, l = Gates.resolve(kind, ctx)
                if not state or STATE_RANK[s] > STATE_RANK[state] then state, layer = s, l end
            end
            if not state then
                -- one recipient (opts.provider, which may be unknown: nil)
                ctx.provider = opts.provider
                state, layer = Gates.resolve(kind, ctx)
            end
            needs[#needs + 1] = { kind = kind, state = state, layer = layer, required = req }
            at[kind] = #needs
            ::continue::
        end
        -- declined for this run where it was optional: a use that needs it
        -- asks again (an Allow once then beats the decline)
        for _idx, n in ipairs(needs) do
            if n.required and n.state == "never" and n.layer == "once" then
                n.state, n.layer = "ask", Gates.isTrusted(features, opts.provider) and "trusted" or "global"
            end
        end
        return needs
    end
    return Gates.needs(action, ctx, { source = opts.source, stamps = opts.stamps, nearby = opts.nearby,
        exists = opts.exists })
end

--- The funnel: resolve what the run wants, refuse a required kind on Never,
--- ask for the kinds on Ask, then run.
--- opts: features (the config the run uses), provider (the dispatch provider),
--- providers + provider_name (with kinds: every provider the data reaches, and
--- the words that name them in the question), decline_once (see ask),
--- path (the book's file, nil = no book), ui, action_name, source, stamps,
--- nearby, amounts (kind = line), note, standing_only, kinds (an explicit list
--- of kinds, for a pick that is not an action), books (a set, see needsForSet),
--- hint, required (with kinds: whether they are required), exists (what the
--- run has to send, Gates.needs), on_cancel (after Cancel), on_refused
--- (after a refusal).
--- run_fn(granted) runs the request; granted.once = the kinds allowed once,
--- with the declined ones mapped to false (Continue without, Allow once
--- without), for the caller's own allowance record (Gates.grantOnce takes
--- both); granted.asked = true when a question was answered (false when
--- nothing needed asking: a caller that merged its own confirm into the
--- question shows it then). Never called after Cancel or a refusal.
function DataAccess.withAccess(plugin, action, opts, run_fn)
    opts = opts or {}
    action = action or {}
    local features = opts.features or {}
    local needs, never_books = DataAccess.needsFor(action, opts)
    local plan = DataAccess.plan(needs)
    if plan.refused then
        DataAccess.refuse(plugin, { kind = plan.refused.kind, layer = plan.refused.layer,
            action_name = opts.action_name or action.text, path = opts.path, ui = opts.ui, hint = opts.hint })
        if opts.on_refused then opts.on_refused() end
        return false
    end
    -- The folder window (round 2, 2026-10-20): with opts.folders (the funnel's
    -- { defaults }), a run that reads the library shows the scan folders to
    -- tick, untick or add for this run; on Ask it is the question itself
    local lib = opts.folders and DataAccess.folderWindowNeed(needs) or nil
    -- a set of books: an allowance for the run, not for one book
    local once_path = opts.path
    if opts.books then once_path = nil end
    if #plan.asked == 0 and not lib then
        -- asked again after More… with nothing left to ask (Library Scan set
        -- to Allow there): the folders ticked in the window still go
        if opts.folders and opts.folders.rows then
            local list = {}
            for _idx, row in ipairs(opts.folders.rows) do
                if row.ticked then list[#list + 1] = row.path end
            end
            Gates.pickFolders(features, once_path, list)
        end
        run_fn({ asked = false })
        return true
    end
    if lib and not opts.folders.rows then
        -- kept on opts: More… asks again with the ticks as they were
        local f = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
        opts.folders.rows = DataAccess.folderRows(opts.folders.defaults,
            type(f.library_scan_folders) == "table" and f.library_scan_folders or {},
            DataAccess.recentFolders(plugin))
    end
    local note = opts.note
    -- the set's note concerns each book's own data: only when such a kind is asked
    if opts.books and plan.per_book then
        local n_books = #opts.books
        local set_note = T(_("One answer for the %1 picked books; each book's own Privacy setting still applies."), n_books)
        if never_books and never_books > 0 then
            set_note = set_note .. " " .. T(_("%1 of them are set to Never and stay out."), never_books)
        end
        note = note and (note .. "\n" .. set_note) or set_note
    end
    local function ticked()
        local list = {}
        for _idx, row in ipairs(lib and opts.folders.rows or {}) do
            if row.ticked then list[#list + 1] = row.path end
        end
        return list
    end
    -- What the window lists: every kind on Ask, and with the folders the
    -- library's kinds the run sends on Allow; the library scan also beside
    -- reading habits asked alone (the books they are read from)
    local habits_asked = false
    for _idx, n in ipairs(needs) do
        if n.kind == "habits" and n.state == "ask" then habits_asked = true end
    end
    local display = {}
    for _idx, n in ipairs(needs) do
        if n.state == "ask"
                or (lib and n.state == "allow" and (n.kind == "book_list" or n.kind == "habits"))
                or (habits_asked and n.state == "allow" and n.kind == "book_list") then
            display[#display + 1] = n
        end
    end
    local show
    -- The answer, judged on the plan the window showed (eff: without the
    -- library's kinds when no folder is ticked)
    local function onAnswer(eff, none)
        return function(choice)
            local asked_kinds = {}
            for _idx, n in ipairs(eff.asked) do asked_kinds[#asked_kinds + 1] = n.kind end
            -- the run's record (Gates.grantOnce: a list = allowed, kind = false =
            -- declined): with no folder ticked the library and the habits read
            -- from its books are declined; the folders picked ride along
            local function record(rec)
                rec = rec or {}
                if none then rec.book_list, rec.habits = false, false end
                Gates.grantOnce(features, once_path, rec)
                if lib then Gates.pickFolders(features, once_path, ticked()) end
                return rec
            end
            -- the optional asked kinds, declined for this run
            local function declined()
                local rec = {}
                for _idx, n in ipairs(eff.asked) do
                    if not n.required then rec[n.kind] = false end
                end
                return rec
            end
            if choice == "once" then
                local rec = {}
                for _idx, kind in ipairs(asked_kinds) do rec[#rec + 1] = kind end
                record(rec)
                run_fn({ once = asked_kinds, asked = true })
            elseif choice == "once_without" then
                local rec = declined()
                for _idx, n in ipairs(eff.asked) do
                    if n.required then rec[#rec + 1] = n.kind end
                end
                record(rec)
                run_fn({ once = rec, asked = true })
            elseif choice == "book" then
                local stored, once = {}, {}
                for _idx, kind in ipairs(asked_kinds) do
                    if Gates.BOOK_KINDS[kind] then stored[#stored + 1] = kind else once[#once + 1] = kind end
                end
                if not writeBookValues(opts.path, opts.ui, stored, true) then
                    -- no book to write to (none known): this run only
                    for _idx, kind in ipairs(stored) do once[#once + 1] = kind end
                end
                if #once > 0 or lib then
                    local rec = {}
                    for _idx, kind in ipairs(once) do rec[#rec + 1] = kind end
                    record(rec)
                end
                run_fn({ once = #once > 0 and once or nil, asked = true })
            elseif choice == "not_book" then
                local stored = {}
                for _idx, kind in ipairs(asked_kinds) do
                    if Gates.BOOK_KINDS[kind] then stored[#stored + 1] = kind end
                end
                writeBookValues(opts.path, opts.ui, stored, false)
                if lib then record({}) end
                run_fn({ asked = true })
            elseif choice == "without" then
                -- recorded on the run's own settings, so a run that passes the
                -- question again (the dispatch's re-entry) is not asked twice
                local rec = record(declined())
                run_fn({ once = rec, asked = true })
            elseif choice == "always" then
                writeAlwaysAllow(plugin, eff.asked, features)
                if lib then record({}) end
                run_fn({ asked = true })
            elseif choice == "run" then
                -- the folder window on Allow: the folders alone
                record({})
                run_fn({ asked = true })
            elseif choice == "more" then
                -- the screen may set a value, for the book or for all books: the
                -- run's own settings take the file's values, then the question is
                -- asked again (it may find nothing left to ask)
                local function again()
                    refreshPrivacyKeys(plugin, features)
                    opts.needs, opts.never_books = nil, nil
                    DataAccess.withAccess(plugin, action, opts, run_fn)
                end
                local trusted_asked = false
                for _idx, n in ipairs(plan.asked) do
                    if n.layer == "trusted" then trusted_asked = true end
                end
                if not plugin then
                    if opts.on_cancel then opts.on_cancel() end
                elseif plan.per_book and opts.path then
                    openBookPrivacy(plugin, opts.path, opts.ui, again)
                elseif trusted_asked and plugin.onKOAssistantSettings then
                    -- judged in the trusted providers' column, which only the
                    -- settings menu holds: open it; the run does not go on
                    plugin:onKOAssistantSettings()
                    if opts.on_cancel then opts.on_cancel() end
                else
                    require("koassistant.books.book_settings").showPrivacyConfig({
                        plugin = plugin, ui = opts.ui, all_books = true, on_close = again,
                    })
                end
            elseif opts.on_cancel then
                opts.on_cancel()
            end
        end
    end
    -- "+ Add folder…": KOReader's folder chooser over the window; a folder
    -- chosen is ticked, remembered among the recent ones (never made
    -- permanent), and the window drawn again once the chooser has closed
    local function addFolder(replace)
        local Device = require("device")
        local start = G_reader_settings:readSetting("home_dir") or Device.home_dir
            or require("datastorage"):getDataDir()
        UIManager:show(require("ui/widget/pathchooser"):new{
            title = _("Add a folder for this run"),
            path = start,
            select_directory = true,
            select_file = false,
            onConfirm = function(path)
                if type(path) ~= "string" or path == "" then return end
                local rows, at = opts.folders.rows, 0
                for i, row in ipairs(rows) do
                    if row.path == path then at = -i break end
                    if row.ticked then at = i end
                end
                if at < 0 then
                    rows[-at].ticked = true
                else
                    table.insert(rows, at + 1, { path = path, ticked = true })
                end
                DataAccess.rememberFolder(plugin, path)
                UIManager:nextTick(function()
                    replace()
                    show()
                end)
            end,
        })
    end
    show = function()
        local none = lib ~= nil and #ticked() == 0
        local eff = plan
        if none then
            local rest = {}
            for _idx, n in ipairs(needs) do
                if n.kind ~= "book_list" and n.kind ~= "habits" then rest[#rest + 1] = n end
            end
            eff = DataAccess.plan(rest)
        end
        local spec_note = note
        if none then
            local why = lib.required and _("Tick or add a folder to run this.")
                or _("No folder ticked: it runs without your library scan.")
            spec_note = spec_note and (spec_note .. "\n" .. why) or why
        end
        DataAccess.ask(plugin, {
            action_name = opts.action_name or action.text,
            provider_name = opts.provider_name or providerName(plugin, opts.provider),
            asked = display, plan = eff, amounts = opts.amounts, note = spec_note,
            set = opts.books ~= nil, standing_only = opts.standing_only, decline_once = opts.decline_once,
            -- no book to hold a value (a picture made outside a book): the
            -- per-book answers could store nothing
            no_book = opts.books == nil and opts.path == nil,
            folders = lib and {
                rows = opts.folders.rows,
                toggle = function(i)
                    opts.folders.rows[i].ticked = not opts.folders.rows[i].ticked
                    show()
                end,
                add = addFolder,
            } or nil,
            -- nothing on Ask: the folders alone (Allow), or nothing to send
            -- and nothing required (Continue without)
            run_only = lib ~= nil and #eff.asked == 0 and lib.state ~= "ask",
            without_only = lib ~= nil and #eff.asked == 0 and none and not lib.required,
            blocked = none and lib.required or false,
        }, onAnswer(eff, none))
    end
    show()
    return true
end

--- The kinds a request's context carried, read from what the gather put in
--- message_data (B395 slice 5): recorded on the chat and on a pin made from
--- it, checked at resume. nil when nothing of the reader's was sent.
function DataAccess.carriedKinds(md)
    md = md or {}
    local function has(key) return type(md[key]) == "string" and md[key] ~= "" end
    local set = {}
    if has("book_text") or has("full_document") or has("incremental_book_text") then set.book_text = true end
    if has("highlights") then set.highlights = true end
    if has("annotations") then set.annotations = true end
    if has("notebook_content") then set.notebook = true end
    if has("library_content") then set.book_list = true end
    if type(md.stats_groups) == "table" and next(md.stats_groups) then set.habits = true end
    if has("surrounding_context") or has("page_text") then set.nearby_text = true end
    -- stored material read along: its stamps (an update's cache, a cache read)
    if md.cached_used_book_text == true then set.book_text = true end
    if md.cached_used_highlights == true then set.highlights = true end
    if md.cached_used_annotations == true then set.annotations = true end
    for kind, used in pairs(md._inherited_stamps or {}) do
        if used then set[kind] = true end
    end
    local out = {}
    for _idx, kind in ipairs(Gates.KINDS) do
        if set[kind] then out[#out + 1] = kind end
    end
    if #out == 0 then return nil end
    return out
end

--- A recorded list of kinds as an artifact's stamps (a pin made from a chat).
--- With no record the pin is stamped as text-free: a chat that recorded
--- nothing sent nothing of the reader's.
function DataAccess.stampsFromKinds(kinds)
    local set = {}
    for _idx, kind in ipairs(kinds or {}) do set[kind] = true end
    return {
        used_book_text = set.book_text == true,
        used_highlights = set.highlights == true,
        used_annotations = set.annotations == true,
        used_notebook = set.notebook == true,
    }
end

--- What a resumed chat needs before its stored context goes out again
--- (B395 slice 5, ruling 16): a kind it carried that is Never now for its
--- book refuses (out.refused = { kind, layer }); toward another provider than
--- the one that answered, the kinds still on Ask are asked once
--- (out.asked). The same provider has the data already: nothing asked.
--- Chats saved before the kinds were recorded pass.
function DataAccess.resumeNeeds(chat, features, provider, path, ui)
    local out = { asked = {} }
    local kinds = chat and chat.data_kinds
    if type(kinds) ~= "table" or #kinds == 0 then return out end
    local ctx = Gates.context(features or {}, provider, { path = path, ui = ui })
    local same_provider = chat.provider ~= nil and chat.provider == provider
    for _idx, kind in ipairs(kinds) do
        local state, layer = Gates.resolve(kind, ctx)
        if state == "never" then
            out.refused = { kind = kind, layer = layer }
            return out
        elseif state == "ask" and not same_provider then
            out.asked[#out.asked + 1] = kind
        end
    end
    return out
end

--- The messages a resumed chat sends when the reader chose to go on without
--- its stored context: the context messages saved with the chat
--- (features._drop_stored_context = how many messages the chat had) stay
--- out; the turns and anything added since ride as they are.
function DataAccess.sendableMessages(messages, features)
    local n = features and features._drop_stored_context
    if type(n) ~= "number" or type(messages) ~= "table" then return messages end
    local out = {}
    for i, m in ipairs(messages) do
        if not (i <= n and type(m) == "table" and m.is_context) then out[#out + 1] = m end
    end
    return out
end

--- The dispatch entry's funnel (the dialogs module's handlePredefinedPrompt):
--- what this request wants, read from the action and the config's transients
--- (the picked source, a section scope, the stored material it reads, the
--- selection's window), with the amounts the reader can judge. Returns true
--- when a question or a refusal is up (the run continues through run_fn, or
--- not at all), false when nothing needs asking (the caller goes on).
-- What a request carries of the book besides its text and the stored summary,
-- whatever the source: an action with one of these has something to go on
-- without the title (the book list included, B514).
local CONTENT_FLAGS = { "use_highlights", "use_annotations", "use_notebook", "use_xray_cache",
    "use_analyze_cache", "use_page_text", "use_library" }

--- Book info None means none (B500): whether an action names the book only
--- through its title, with nothing of the book itself to go on in THIS run,
--- so it cannot run while the AI is told nothing about the book. Judged on
--- what the run sends, not on what the action could use (B514): the text
--- goes unless the picked source is the summary or AI knowledge, the summary
--- only when the picked source is the summary (or the action has no source
--- popup), the reader's material, the caches and the book list whatever the
--- source. Pure.
function DataAccess.needsTitle(action, source)
    action = action or {}
    local prompt = action.prompt
    if not prompt and action.template then
        local ok, Templates = pcall(require, "koassistant.prompts.templates")
        prompt = ok and Templates and Templates.get(action.template) or nil
    end
    if type(prompt) ~= "string" or not prompt:find("{title}", 1, true) then return false end
    if action.use_book_text and source ~= "ai_knowledge" and source ~= "summary" then return false end
    if action.use_summary_cache and (source == nil or source == "summary") then return false end
    for _idx, flag in ipairs(CONTENT_FLAGS) do
        if action[flag] then return false end
    end
    return true
end

--- The refusal for an action that needs the title while Book info is None.
--- spec: action_name, layer ("chat" | "book" | "global"), path, ui.
function DataAccess.refuseNoTitle(plugin, spec)
    logger.dbg("KOAssistant data access: refused, no title, layer", spec.layer, "for", spec.action_name or "?")
    local where
    if spec.layer == "chat" then
        where = _("for this chat (the gear menu's Send book info is off); turn it on there to run it")
    elseif spec.layer == "book" then
        where = _("for this book (Book Settings → Privacy & Data)")
    else
        where = _("for all books (Settings → Privacy & Data)")
    end
    local text = T(_("%1 answers from what the AI knows about the book, which it cannot do without the title, and Book info is set to None %2."),
        spec.action_name or _("This action"), where)
    local dialog
    local rows = {}
    if spec.layer == "book" and spec.path then
        rows[#rows + 1] = { { text = _("Change for this book…"), callback = function()
            UIManager:close(dialog)
            require("koassistant.books.book_settings").showBookInfoPicker({
                plugin = plugin, ui = spec.ui, document_path = spec.path, target_override = "book",
            })
        end } }
    elseif spec.layer == "global" and plugin then
        -- Book info lives under Settings → Privacy & Data
        rows[#rows + 1] = { { text = _("Open Settings"), callback = function()
            UIManager:close(dialog)
            require("koassistant.books.book_settings").showPrivacyConfig({
                plugin = plugin, ui = spec.ui, all_books = true,
            })
        end } }
    end
    rows[#rows + 1] = { { text = _("Close"), id = "close", callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{ title = text, buttons = rows }
    UIManager:show(dialog)
end

function DataAccess.askForDispatch(plugin, action, features, ui, config, run_fn)
    local cf = features or {}
    -- The book this request is about (the dispatch's own per-book rule): a
    -- book-level request names its target, a highlight belongs to the open
    -- book, a library request may carry picked books, a general one none
    local path, books
    if cf.is_library_context then
        if type(cf.books_info) == "table" and #cf.books_info > 0 then
            books = {}
            for _idx, b in ipairs(cf.books_info) do
                if type(b) == "table" and b.file then books[#books + 1] = { file = b.file, title = b.title } end
            end
            if #books == 0 then books = nil end
        end
    elseif cf.is_general_context then
        path = nil
    elseif cf.is_book_context then
        path = (cf.book_metadata and cf.book_metadata.file) or (ui and ui.document and ui.document.file)
    else
        path = (ui and ui.document and ui.document.file) or (cf.book_metadata and cf.book_metadata.file)
    end
    local provider = require("koassistant.ui.dialogs").effectiveDispatchProvider(
        cf, action, action.provider or (config and config.provider))
    local sm = cf._source_mode
    -- A refusal or a Cancel: the chat this run would have opened never starts
    -- (an input dialog closes before its action dispatches), so the chat's
    -- allowance ends here, never reaching a later request; the same for every
    -- other just-in-time key the dispatch would have consumed from this config
    -- (a run option, the chips' state, the scope pick: Dialogs.DISPATCH_TRANSIENTS),
    -- which a shared config would otherwise hand to the next, unrelated request
    local function drop()
        require("koassistant.ui.dialogs").dropDispatchTransients(cf)
    end
    -- Book info None (B500): an action with nothing of the book to go on but
    -- its title says so, instead of asking the AI about "this book"
    if cf.is_book_context and DataAccess.needsTitle(action, sm) then
        local BookSettings = require("koassistant.books.book_settings")
        local ds = path and require("koassistant.storage.doc_settings").resolve(path, ui) or nil
        if BookSettings.resolveBookInfoLevel(ds, cf) == "none" then
            local layer = "global"
            if cf._session_book_info == false then
                layer = "chat"   -- the dialog's Send book info switch (over the setting)
            elseif ds and ds:readSetting(BookSettings.KEY_BOOK_INFO) == "none" then
                layer = "book"
            end
            DataAccess.refuseNoTitle(plugin, { action_name = action.text or action.id,
                layer = layer, path = path, ui = ui })
            drop()
            return true
        end
    end
    local live = ui and ui.document and ui.document.file ~= nil and ui.document.file == path
    -- The stored material the run will read: its stamps are the kinds it needs
    local stamps
    if path and (action.use_xray_cache or action.use_analyze_cache or action.use_summary_cache or sm == "summary") then
        local ok, CE = pcall(require, "koassistant.request.context_extractor")
        if ok and CE then
            local ex = CE:new(live and ui or nil, { document_path = path })
            local function stored(get)
                local okr, r = pcall(get)
                if okr and type(r) == "table" and type(r.text) == "string" and r.text ~= "" then return r end
                return nil
            end
            stamps = {}
            if action.use_xray_cache then stamps.xray = stored(function() return ex:getXrayCache() end) end
            if action.use_analyze_cache then stamps.analyze = stored(function() return ex:getAnalyzeCache() end) end
            if action.use_summary_cache or sm == "summary" then
                stamps.summary = stored(function() return ex:getSummaryCache() end)
            end
        end
    end
    -- The run's own saved result, when the run continues it (an action with
    -- an update prompt, not a rebuild): its stamps are asked too
    -- (Gates.needs, stamps.own)
    local own_amounts
    if path and action.update_prompt and action.id and not cf._xray_rebuild and not cf._ladder_fresh then
        local okc, ActionCache = pcall(require, "koassistant.artifacts.action_cache")
        local okg, own = pcall(function() return okc and ActionCache.get(path, action.id) end)
        if okg and type(own) == "table" and own.result then
            local kinds
            kinds, own_amounts = DataAccess.baseKinds(own, action.text or action.id)
            if #kinds > 0 then
                stamps = stamps or {}
                stamps.own = own
            end
        end
    end
    local prompt_text = action.prompt or ""
    local nearby = prompt_text:find("{page_text", 1, true) ~= nil
    -- The context around a selection, only when this run will carry it: the
    -- dispatch's own resolution (the action's flag over the session, book or
    -- global mode, None by default); an X-Ray chat's pseudo-selection never
    if not nearby and cf._selection_context_window ~= nil and not cf._xray_context_prefix then
        local ok_ds, sc_ds = pcall(function() return require("koassistant.storage.doc_settings").resolve(path, ui) end)
        local ambient = cf._highlight_context_active
            or require("koassistant.books.book_settings").resolveHighlightContext(ok_ds and sc_ds or nil, cf)
        nearby = require("koassistant.prompts.actions").effectiveSurroundingContextMode(action, cf, ambient) ~= nil
    end
    -- the dictionary's context channel ({context}), when the book's mode sends any
    if not nearby and live and not cf._non_document_selection
            and (prompt_text:find("{context}", 1, true) or prompt_text:find("{context_section}", 1, true)) then
        local ok_ds, ds = pcall(function() return require("koassistant.storage.doc_settings").resolve(path, ui) end)
        local mode = require("koassistant.books.book_settings").resolveDictionaryContext(ok_ds and ds or nil, cf)
        nearby = mode ~= nil and mode ~= "none"
    end
    -- The amounts, where known
    local amounts = {}
    if cf._section_scope and cf._section_scope.label then
        amounts.book_text = T(_("the text of \"%1\" from this book"), cf._section_scope.label)
    elseif cf._highlight_section_scope then
        amounts.book_text = _("text from this book, the part you chose")
    elseif sm == "smart_retrieval" then
        amounts.book_text = _("the passages it looks up in this book")
    elseif sm == "summary" then
        amounts.book_text = _("a summary built from this book's text")
    elseif cf._full_document_xray or cf._update_to_full_progress
            or prompt_text:find("{full_document", 1, true)
            or (sm ~= nil and sm ~= "ai_knowledge" and prompt_text:find("{document_context", 1, true)) then
        amounts.book_text = _("the whole text of this book")
    else
        local pct
        if live then
            local ok, CE = pcall(require, "koassistant.request.context_extractor")
            if ok and CE then
                local okp, p = pcall(function() return CE:new(ui):getReadingProgress() end)
                if okp and type(p) == "table" and p.formatted then pct = p.formatted end
            end
        end
        amounts.book_text = pct and T(_("text from this book, up to your position (%1)"), pct)
            or _("text from this book, up to your reading position")
    end
    if live and ui.annotation and type(ui.annotation.annotations) == "table" then
        local n, notes = 0, 0
        for _idx, a in ipairs(ui.annotation.annotations) do
            if require("koassistant.request.context_extractor").isHighlight(a) then
                n = n + 1
                if type(a.note) == "string" and a.note ~= "" then notes = notes + 1 end
            end
        end
        amounts.highlights = T(_("your highlights (%1)"), n)
        amounts.annotations = T(_("your notes on highlights (%1)"), notes)
    end
    -- A kind asked only for the saved result's sake says so: the run sends
    -- the result, not today's highlights
    if stamps and stamps.own and own_amounts then
        if not action.use_highlights and not action.use_annotations then
            amounts.highlights = own_amounts.highlights or amounts.highlights
        end
        if not action.use_annotations then
            amounts.annotations = own_amounts.annotations or amounts.annotations
        end
    end
    -- What the run has to send (2026-10-20): an optional kind with nothing
    -- behind it is not asked (Gates.needs opts.exists): the reading habits
    -- without KOReader's statistics. The library is there to pick (round 2):
    -- the folder window lists the default folders and the recent ones, to
    -- tick for this run. A run started from the library dialog picked its
    -- folders there, before the action (its Library Scan ▾): no window, the
    -- question names them.
    local exists = {}
    local library_run = cf.is_library_context == true
    local folders = DataAccess.scanFolders(plugin, library_run, cf)
    if action.use_advanced_stats then
        local okS, StatsReader = pcall(require, "koassistant.books.stats_reader")
        if not (okS and StatsReader and StatsReader.isAvailable and StatsReader.isAvailable()) then
            exists.habits = false
        end
    end
    -- the window answered already (the dispatch's re-entry): its folders
    local picked = type(cf._data_once) == "table" and type(cf._data_once.folders) == "table"
    if picked or library_run then
        amounts.book_list, amounts.habits = DataAccess.libraryAmounts(folders)
    else
        amounts.book_list, amounts.habits = DataAccess.windowAmounts()
    end
    if live and ui.annotation and type(ui.annotation.annotations) == "table" then
        local n, notes = 0, 0
        for _idx, a in ipairs(ui.annotation.annotations) do
            if require("koassistant.request.context_extractor").isHighlight(a) then
                n = n + 1
                if type(a.note) == "string" and a.note ~= "" then notes = notes + 1 end
            end
        end
        -- (an action that updates its own result keeps asking: the result
        -- may carry highlights deleted since)
        if not action.use_response_caching then
            if n == 0 then exists.highlights = false end
            if notes == 0 then exists.annotations = false end
        end
    end
    if path and action.use_notebook then
        local okN, Notebook = pcall(require, "koassistant.chat.notebook")
        if okN and Notebook and Notebook.exists then
            local okE, has = pcall(Notebook.exists, path)
            if okE and has == false then exists.notebook = false end
        end
    end
    local opts = { features = cf, provider = provider, path = path, ui = ui, books = books,
        action_name = action.text or action.id, source = sm, stamps = stamps, nearby = nearby,
        amounts = amounts, hint = action.blocked_hint, exists = exists,
        folders = not (picked or library_run) and { defaults = folders } or nil }
    local needs, never_books = DataAccess.needsFor(action, opts)
    local window = opts.folders and DataAccess.folderWindowNeed(needs)
    if not window and #folders == 0 then
        -- no window and no folder (a run that only can use the list, on
        -- Allow, or the library dialog with nothing ticked): no list goes,
        -- nor the reading habits read from its books
        exists.book_list, exists.habits = false, false
        needs, never_books = DataAccess.needsFor(action, opts)
        -- the library dialog greys an action that needs the list until a
        -- folder is ticked there; one that gets through is refused
        for _idx, n in ipairs(library_run and needs or {}) do
            if n.kind == "book_list" and n.required and n.state ~= "never" then
                UIManager:show(InfoMessage:new{
                    text = _("No scan folder is ticked in this library dialog.\n\nTick one under Library Scan."),
                })
                drop()
                return true
            end
        end
    end
    local plan = DataAccess.plan(needs)
    if not plan.refused and #plan.asked == 0 and not window then return false end
    opts.needs, opts.never_books = needs, never_books
    opts.on_cancel, opts.on_refused = drop, drop
    DataAccess.withAccess(plugin, action, opts, run_fn)
    return true
end

--- A one-time notice after the upgrade that made Ask the default (ruling 2
--- of 2026-10-14). Shown at the first interaction, before other prompts;
--- the pending flag is written by the migration.
--- @return boolean shown
function DataAccess.maybeShowUpgradeNotice(plugin)
    if not (plugin and plugin.settings) then return false end
    local f = plugin.settings:readSetting("features") or {}
    if not f._privacy_notice_pending then return false end
    f._privacy_notice_pending = nil
    plugin.settings:saveSetting("features", f)
    plugin.settings:flush()
    UIManager:show(InfoMessage:new{
        text = _("Privacy has been redone.") .. "\n\n"
            .. _("KOAssistant now asks before it sends your highlights, notes, notebook, book text, library scan or reading habits for the first time, and remembers your answer for the book. Every sharing switch in Settings → Privacy & Data is set to Ask; your per-book settings and trusted providers are kept.")
            .. "\n\n" .. _("Each switch can also be set to Allow (sent without asking) or Never."),
    })
    return true
end

return DataAccess
