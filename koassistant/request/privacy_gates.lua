--[[
The ONE place that decides whether a kind of the reader's data may go into a
request (docs/data_access_picture.md sections 4.2 and 4.5, B074 / B395).

Pure: everything comes in through `ctx`, nothing is read from KOReader here.
The sites that used to decide for themselves (the extractor, the pre-flight,
the Scope chip, the attachments, the tool runner, the background X-Ray check,
the merge check, the library dialog, the multi-book loop, the update re-check,
the X-Ray browser, the unified popup) ask `resolve` / `allows` instead, and
tests/unit/test_privacy_gates.lua fails when any other file compares a privacy
switch or walks `trusted_providers` itself (`-- raw-gate: <reason>` escapes).

The model (slice 2, rulings 1, 19 to 22 of 2026-10-14): every kind has one of
three states, "allow", "ask" or "never", and the answer carries the layer
that gave it:
  1. the book's own Never (Book Settings > Privacy & Data)       "book"
  2. an allowance given for this run (Allow once)                  "once"
  3. the book's own Allow                                          "book"
  4. the column of the provider the request goes to: a trusted
     provider reads the trusted column (default Allow), everyone
     else the global switch (default Ask)                          "trusted" | "global"
Reading position is two-valued (on unless off, never asked). Allowing notes
allows highlights; Never for highlights is Never for notes. The question
itself and the funnel that asks it are koassistant/ui/data_access.lua.

Storage: the seven global keys keep their names; `true` is Allow, unset or
`false` is Ask, the string "never" is Never (an older build reads "never" as
off, so a downgrade fails closed). The eighth kind and the trusted column are
string-valued keys ("allow" | "ask" | "never"), unset = their default.
]]

local Gates = {}

--- The kinds of data that can leave the device (section 1 of the picture).
--- nearby_text is the eighth kind (ruled 2026-10-14): the bounded text around
--- what the reader taps (the context around a selection, the current page,
--- the dictionary's context, the image prompt's surrounding text).
Gates.KINDS = { "book_text", "highlights", "annotations", "notebook", "position",
    "habits", "book_list", "nearby_text" }

--- The kinds a book can hold its own value for (Book Settings > Privacy & Data).
Gates.BOOK_KINDS = { book_text = true, highlights = true, annotations = true,
    notebook = true, nearby_text = true }

--- Each kind's global switch (the column for every provider that is not trusted).
Gates.GLOBAL_KEY = {
    book_text   = "enable_book_text_extraction",
    highlights  = "enable_highlights_sharing",
    annotations = "enable_annotations_sharing",
    notebook    = "enable_notebook_sharing",
    position    = "enable_basic_stats",
    habits      = "enable_advanced_stats",
    book_list   = "enable_library_scanning",
    nearby_text = "nearby_text_sharing",
}

--- Each kind's value for trusted providers (the trusted column, default Allow).
Gates.TRUSTED_KEY = {
    book_text   = "trusted_book_text",
    highlights  = "trusted_highlights",
    annotations = "trusted_annotations",
    notebook    = "trusted_notebook",
    position    = "trusted_position",
    habits      = "trusted_habits",
    book_list   = "trusted_book_list",
    nearby_text = "trusted_nearby_text",
}

--- The states, for callers that compare.
Gates.ALLOW, Gates.ASK, Gates.NEVER = "allow", "ask", "never"

--- Is this provider on the trusted list? One copy.
function Gates.isTrusted(features, provider)
    if type(features) ~= "table" or not provider then return false end
    if type(features.trusted_providers) ~= "table" then return false end
    for _idx, id in ipairs(features.trusted_providers) do
        if id == provider then return true end
    end
    return false
end

-- One key's own state in the global column: true = allow, "never" = never,
-- anything else = ask.
local function switchState(v)
    if v == true or v == "allow" then return "allow" end
    if v == "never" then return "never" end
    return "ask"
end

-- One key's own state in a string-valued column with a default.
local function stringState(v, default)
    if v == "allow" or v == true then return "allow" end
    if v == "never" then return "never" end
    if v == "ask" then return "ask" end
    return default
end

-- The raw state of one kind in a column, before the pairing.
local function rawColumnState(features, kind, trusted)
    if trusted then
        local v = features[Gates.TRUSTED_KEY[kind]]
        if kind == "position" then
            -- two-valued: on unless off
            if v == false or v == "never" then return "never" end
            return "allow"
        end
        return stringState(v, "allow")
    end
    local v = features[Gates.GLOBAL_KEY[kind]]
    if kind == "position" then
        if v == false or v == "never" then return "never" end
        return "allow"
    end
    if kind == "nearby_text" then
        return stringState(v, "allow")
    end
    return switchState(v)
end

--- A kind's own value for all books (the column for every provider that is
--- not trusted), before the pairing: what the global switch itself holds, for
--- the pickers that show and write it.
--- @return string "allow" | "ask" | "never"
function Gates.globalState(features, kind)
    return rawColumnState(features or {}, kind, false)
end

--- A column's state for a kind, with the pairing of highlights and notes:
--- allowing notes allows highlights, Never for highlights is Never for notes.
--- trusted = read the trusted column (the provider is trusted).
--- @return string "allow" | "ask" | "never"
function Gates.columnState(features, kind, trusted)
    features = features or {}
    local own = rawColumnState(features, kind, trusted)
    if kind == "highlights" then
        if own == "never" then return "never" end
        if own == "allow" then return "allow" end
        if rawColumnState(features, "annotations", trusted) == "allow" then return "allow" end
        return "ask"
    end
    if kind == "annotations" then
        if own == "never" then return "never" end
        if rawColumnState(features, "highlights", trusted) == "never" then return "never" end
        return own
    end
    return own
end

--- The kinds a run was allowed once, for this book: features._data_once =
--- { book = <path or nil>, kinds = { kind = true | false } } rides the request's own
--- config copy (koassistant/ui/data_access.lua grants it; the dispatch consumes
--- it from the source config). A record without a book covers every book of
--- the run (a request over many picked books); one with a book covers that
--- book alone. A kind mapped to false was declined for this run ("Continue
--- without"): resolve reads it as Never for the run alone. Never persisted.
--- @return table|nil the set of kinds, nil when nothing stands
function Gates.onceFor(features, path)
    local once = type(features) == "table" and features._data_once
    if type(once) ~= "table" or type(once.kinds) ~= "table" then return nil end
    if once.book ~= nil and path ~= nil and once.book ~= path then return nil end
    if once.book ~= nil and path == nil then return nil end
    return once.kinds
end

--- Record an allowance for this run on a features table (the config copy the
--- run uses). Merges into a record for the same book; a different book's
--- record is replaced. `kinds` lists the kinds allowed and may also map a
--- kind to false: declined for this run (the question's Continue without),
--- so a run that passes the question again (the dispatch's re-entry) is not
--- asked twice and its gather leaves the kind out. An allowance beats a
--- decline of the same kind.
function Gates.grantOnce(features, path, kinds)
    if type(features) ~= "table" or type(kinds) ~= "table" then return end
    local once = features._data_once
    if type(once) ~= "table" or type(once.kinds) ~= "table" or once.book ~= path then
        once = { book = path, kinds = {} }
        features._data_once = once
    end
    for k, v in pairs(kinds) do
        if type(k) == "number" then
            once.kinds[v] = true
        elseif v == false then
            if once.kinds[k] ~= true then once.kinds[k] = false end
        elseif v then
            once.kinds[k] = true
        end
    end
end

--- Record the scan folders picked for this run (the folder window,
--- 2026-10-20) on the run's allowance record, beside its kinds: every gather
--- reads them first (DataAccess.scanFolders), and the dispatch's re-entry
--- finds the pick made. An empty list = no list for this run.
function Gates.pickFolders(features, path, folders)
    if type(features) ~= "table" or type(folders) ~= "table" then return end
    Gates.grantOnce(features, path, {})
    features._data_once.folders = folders
end

--- Whether a kind may go into the request, and which layer said so.
--- ctx.features  the settings the request runs under (configuration.features,
---               or the extractor's own settings table)
--- ctx.provider  the provider the request really goes to (dispatchProvider)
--- ctx.book      the book's own values, BookSettings.effectivePrivacyOverrides
---               (nil = none known); its Never beats everything, its Allow
---               needs no switch
--- ctx.once      the kinds allowed for this run (Gates.onceFor), nil = none;
---               a kind mapped to false was declined for this run
--- @return string state "allow" | "ask" | "never"; string layer "book" | "once" | "trusted" | "global"
---   ("never" with layer "once" = declined for this run)
function Gates.resolve(kind, ctx)
    ctx = ctx or {}
    local book = ctx.book
    if type(book) == "table" and book[kind] == false then
        return "never", "book"
    end
    if type(ctx.once) == "table" then
        if ctx.once[kind] == false then return "never", "once" end
        if ctx.once[kind] then return "allow", "once" end
    end
    if type(book) == "table" and book[kind] == true then
        return "allow", "book"
    end
    local trusted = Gates.isTrusted(ctx.features, ctx.provider)
    return Gates.columnState(ctx.features, kind, trusted), trusted and "trusted" or "global"
end

--- The yes-or-no every enforcement site needs: only "allow" sends. A kind on
--- Ask is not sent until the question was answered (the funnel turns the
--- answer into ctx.once or the book's value), so a site the funnel missed
--- errs toward sending less.
function Gates.allows(kind, ctx)
    local state = Gates.resolve(kind, ctx)
    return state == "allow"
end

--- Whether a kind can be offered at all (a row, a chip, a scope): everything
--- but Never. The question comes at the run.
function Gates.usable(kind, ctx)
    local state = Gates.resolve(kind, ctx)
    return state ~= "never"
end

--- Every kind's state for a book, for the surfaces (the tile, the screen).
function Gates.summary(ctx)
    local out = {}
    for _idx, kind in ipairs(Gates.KINDS) do
        local state, layer = Gates.resolve(kind, ctx)
        out[kind] = { state = state, layer = layer }
    end
    return out
end

--- The kinds a stored artifact was built from, by its stamps. A missing text
--- stamp means built from text (the legacy rule); the highlights stamp falls
--- back to the old annotations stamp; the annotations stamp counts only on
--- caches that tracked both.
--- @return table { book_text = boolean, highlights = boolean, annotations = boolean }
function Gates.stampedKinds(entry)
    entry = entry or {}
    return {
        book_text = entry.used_book_text ~= false,
        highlights = entry.used_highlights == true
            or (entry.used_highlights == nil and entry.used_annotations == true),
        annotations = entry.used_annotations == true and entry.used_highlights ~= nil,
        -- stamped since B395 slice 5; an older entry never read the notebook
        notebook = entry.used_notebook == true,
    }
end

--- The same stamps as a list of kinds, in KINDS order, for a question's
--- opts.kinds (an artifact chat, an attached artifact, a merge's set).
function Gates.stampedList(entry)
    local k = Gates.stampedKinds(entry)
    local out = {}
    for _idx, kind in ipairs(Gates.KINDS) do
        if k[kind] then out[#out + 1] = kind end
    end
    return out
end

--- The book's own values for ctx.book, from a DocSettings or the facade a
--- site already holds. Never throws; nil when nothing is known.
function Gates.overridesOf(ds)
    if not ds then return nil end
    local ok, out = pcall(function()
        return require("koassistant.books.book_settings").effectivePrivacyOverrides(ds)
    end)
    if ok and type(out) == "table" then return out end
    return nil
end

--- The book's own values for ctx.book, by path (nil = the open book of `ui`).
--- Never throws; nil when nothing is known.
function Gates.bookOverrides(path, ui)
    local ok, ds = pcall(function()
        return require("koassistant.storage.doc_settings").resolve(path, ui)
    end)
    if not (ok and ds) then return nil end
    return Gates.overridesOf(ds)
end

--- Copy every key the gates read from one features table into another (the
--- extractor's settings table is built field by field): the global switches,
--- the trusted column, the trusted list, the run's allowance and the chat's
--- own choices.
--- @return table `to`
function Gates.copyPrivacy(from, to)
    to = to or {}
    if type(from) ~= "table" then return to end
    for _kind, key in pairs(Gates.GLOBAL_KEY) do to[key] = from[key] end
    for _kind, key in pairs(Gates.TRUSTED_KEY) do to[key] = from[key] end
    to.trusted_providers = from.trusted_providers
    to._data_once = from._data_once
    return to
end

--- A whole ctx for a site: the features, the provider, the book's own values
--- (from opts.book, else opts.ds, else opts.path / opts.ui) and the once set
--- for opts.path.
function Gates.context(features, provider, opts)
    opts = opts or {}
    local book = opts.book
    if book == nil and opts.ds then book = Gates.overridesOf(opts.ds) end
    if book == nil and (opts.path or opts.ui) then book = Gates.bookOverrides(opts.path, opts.ui) end
    return { features = features, provider = provider, book = book,
        once = Gates.onceFor(features, opts.path) }
end

--- The kinds a run wants, from the action's declarations and what the run
--- will read, each with its state and whether the action cannot run without
--- it (section 4.5 `needs`). Pure: the caller passes what it knows.
--- opts.source   the source popup's pick: "full_text" | "summary" |
---               "section_summary" | "smart_retrieval" | "ai_knowledge" | nil
--- opts.stamps   the artifacts the run will read, by placeholder:
---               { xray = entry, analyze = entry, summary = entry } (an entry
---               = its stamps; nil = nothing stored, nothing to ask)
--- opts.nearby   true when the run carries text around a selection or the
---               current page
--- opts.exists   what the run has to send, where the caller knows it: a kind
---               mapped to false has nothing behind it (book_list: no scan
---               folder; habits: no reading statistics; highlights,
---               annotations, notebook: none in the book). An optional kind
---               with nothing behind it is not asked (nothing would go); a
---               required one stays (its own check refuses), and so does one
---               a stored artifact the run reads was built from. nil = unknown.
--- @return table list of { kind, state, layer, required = boolean }, in KINDS order
function Gates.needs(action, ctx, opts)
    action = action or {}
    opts = opts or {}
    local wanted, required, stored = {}, {}, {}
    local function want(kind, req)
        wanted[kind] = true
        if req then required[kind] = true end
    end
    local reqs = {}
    for _idx, r in ipairs(action.requires or {}) do reqs[r] = true end
    local prompt = action.prompt or ""
    local source = opts.source
    -- Book text: the action's flag, unless the reader picked a source that
    -- needs none; a picked text source or a declared requirement is required
    if source == "ai_knowledge" or source == "summary" then
        -- nothing from the text itself (a summary's own stamps are asked below)
    elseif action.use_book_text and action.use_book_text ~= false then
        local text_source = source == "full_text" or source == "section_summary"
            or source == "smart_retrieval"
        if text_source or reqs.book_text or prompt:find("{book_text", 1, true)
                or prompt:find("{full_document", 1, true)
                or prompt:find("{document_context", 1, true)
                or prompt:find("{incremental_book_text", 1, true) then
            want("book_text", text_source or reqs.book_text)
        end
    end
    if action.use_highlights then want("highlights", reqs.highlights) end
    if action.use_annotations then
        want("annotations", false)
        -- notes carry their highlights: a required highlights kind stays
        want("highlights", reqs.highlights)
    end
    if action.use_notebook then want("notebook", false) end
    if action.use_library then
        want("book_list", reqs.library)
        if action.use_advanced_stats then want("habits", false) end
    end
    if opts.nearby then want("nearby_text", false) end
    -- Stored material the run will read: its stamps are the kinds it needs
    local stamps = opts.stamps or {}
    -- (stored[kind]: the stored material carries the kind whatever the book
    -- holds now, so opts.exists never drops it)
    if action.use_xray_cache and stamps.xray then
        local k = Gates.stampedKinds(stamps.xray)
        if k.book_text then want("book_text", false); stored.book_text = true end
        if k.highlights then want("highlights", false); stored.highlights = true end
        if k.annotations then want("annotations", false); stored.annotations = true end
    end
    if action.use_analyze_cache and stamps.analyze and Gates.stampedKinds(stamps.analyze).book_text then
        want("book_text", false); stored.book_text = true
    end
    -- The summary goes only where the dispatch sends it: the "summary" source,
    -- or an action without a source pick that reads it (another source drops it)
    local summary_read = source == "summary" or (action.use_summary_cache and source == nil)
    if summary_read and stamps.summary and Gates.stampedKinds(stamps.summary).book_text then
        want("book_text", false); stored.book_text = true
    end
    -- The run's own saved result, when the run continues it (an update sends
    -- it back with the new text): what it was built with beyond the book's
    -- text is a kind the run needs too, optional (declined, the run starts
    -- over from the text). Until 2026-11-12 the question named the text
    -- alone, and the dispatch then withheld a result built with highlights
    -- whatever the reader had answered: an X-Ray from when X-Rays read
    -- highlights was rebuilt in full by every update and never continued by
    -- a checkpoint step.
    if stamps.own then
        local k = Gates.stampedKinds(stamps.own)
        if k.highlights then want("highlights", false); stored.highlights = true end
        if k.annotations then want("annotations", false); stored.annotations = true end
    end
    local exists = opts.exists or {}
    local out = {}
    for _idx, kind in ipairs(Gates.KINDS) do
        if wanted[kind] and kind ~= "position"
                and not (exists[kind] == false and not required[kind] and not stored[kind]) then
            local state, layer = Gates.resolve(kind, ctx)
            -- declined for this run where it was optional: a use that needs it
            -- asks again (an Allow once then beats the decline)
            if state == "never" and layer == "once" and required[kind] then
                state, layer = "ask", Gates.isTrusted(ctx.features, ctx.provider) and "trusted" or "global"
            end
            out[#out + 1] = { kind = kind, state = state, layer = layer,
                required = required[kind] == true }
        end
    end
    return out
end

--- The provider a request really goes to, the way the bake applies it: a run
--- option's picked model beats the action's own pin, then a pending one-shot
--- model pick, then the Quick preset's model (only for an action that accepts
--- Quick), then a usable global tier pin for the action's tier hint, then the
--- base provider. Judging trust against anything earlier let data extracted
--- under a trusted provider's bypass go to an untrusted one (audit v0.20.0
--- finding C4 and its re-openings). Reads only; consumption stays in the bake.
--- quick_model_fn resolves the Quick preset's model (the dialogs module's
--- resolveQuickPresetModel); when absent, the loaded dialogs module's is used.
function Gates.dispatchProvider(features, action, base_provider, quick_model_fn)
    features = features or {}
    local rv = features._run_variant
    if type(rv) ~= "table" then rv = nil end
    if rv and rv.provider then return rv.provider end
    if action and action.provider then return base_provider end
    -- The *_active consumables are set just-in-time at dispatch; before that
    -- point (the freeform Send's scope check) the same pending state lives in
    -- the _session_* chip keys. Direct entries drop inherited chip state, then
    -- may seed the quick consumable from the Quick Answer default.
    local override = features._model_override_active or features._session_model
    if override and override.provider then return override.provider end
    local quick = features._quick_answer_active or features._session_quick_answer
    if rv and rv.quick ~= nil
            and not require("koassistant.request.run_options").isModelOnly(action) then
        quick = rv.quick
    end
    if quick and action and action.accept_quick_answer ~= true then quick = nil end
    if quick then
        local resolver = quick_model_fn
        if not resolver then
            local D = package.loaded["koassistant.ui.dialogs"]
            resolver = D and D.resolveQuickPresetModel or nil
        end
        local preset = resolver and resolver(features, base_provider)
        if preset and preset.provider then return preset.provider end
    end
    -- Per-action tier hint (weakest rung): a usable GLOBAL tier pin re-points
    -- the dispatch provider; ladder hits return the base provider unchanged.
    if features.use_action_tiers ~= false and action and action.model_tier
            and not action.provider and not action.model then
        local p2 = require("koassistant.request.model_lists")
            .resolveTierTarget(base_provider, action.model_tier)
        if p2 then return p2 end
    end
    return base_provider
end

--- A privacy preset written onto a features table (ruling 10 of 2026-10-14;
--- the Privacy & Data preset row in main.lua): "full" = Allow for every kind,
--- "minimal" = Never for every kind and reading position off, "default" =
--- every value cleared, the trusted column's included (B499), so each reads
--- the default it ships with (Ask; reading position on, the text around what
--- you tap Allow; Allow for trusted providers) and a later change of a default
--- reaches the reader (B498). Per-book values and the trusted list are
--- untouched, and "full" and "minimal" leave the trusted column alone; an
--- unknown preset changes nothing. Pure.
function Gates.applyPreset(features, preset)
    if preset ~= "full" and preset ~= "minimal" and preset ~= "default" then return features end
    for _idx, kind in ipairs(Gates.KINDS) do
        local key = Gates.GLOBAL_KEY[kind]
        if preset == "default" then
            features[key] = nil
            features[Gates.TRUSTED_KEY[kind]] = nil
        elseif kind == "position" then
            features[key] = preset == "full"
        elseif kind == "nearby_text" then
            features[key] = preset == "full" and "allow" or "never"
        else
            features[key] = preset == "full" or "never"
        end
    end
    return features
end

-- The state each kind ships with, in the column for every provider.
local DEFAULT_STATE = { position = "allow", nearby_text = "allow" }

--- The preset the values match, for the "Preset: <name>" row (B499, the X-Ray
--- presets' rule): "default" when both columns read their defaults, "full"
--- when every kind is Allow for all books, "minimal" when every kind is Never
--- for all books (reading position off); nil = Custom. Pure.
function Gates.presetOf(features)
    features = features or {}
    local full, minimal, default = true, true, true
    for _idx, kind in ipairs(Gates.KINDS) do
        local state = rawColumnState(features, kind, false)
        if state ~= "allow" then full = false end
        if state ~= "never" then minimal = false end
        if state ~= (DEFAULT_STATE[kind] or "ask")
                or rawColumnState(features, kind, true) ~= "allow" then
            default = false
        end
    end
    if default then return "default" end
    if full then return "full" end
    if minimal then return "minimal" end
    return nil
end

return Gates
