--[[--
Per-book (per-document) settings.

Shared home for settings that can be overridden per book: domain, research mode,
and (incrementally) spoiler-free, book-info inclusion, AI title/author overrides,
and per-action settings (quiz, language). Reachable from the input dialog, the
Quick Settings panel, the Quick Actions panel, and the file browser.

Step 1 extracts the Domain & Research picker that was duplicated between
koassistant_dialogs.lua (input-dialog closure) and main.lua (Quick Settings popup).
The button-building logic lives here once; each caller supplies the current state
and callbacks that perform the actual persistence + UI refresh, so each keeps its
own integration (in-memory config mutation + refreshInputDialog vs
saveSetting/flush + updateConfigFromSettings).
]]

local _ = require("koassistant_gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local DomainLoader = require("domain_loader")
local Languages = require("koassistant_languages")

local BookSettings = {}

-- Per-book DocSettings sidecar keys.
-- AI title/author are tri-state: nil = use the book's real metadata; "" = send empty
-- (suppress entirely); any other string = that custom value.
BookSettings.KEY_AI_TITLE = "koassistant_book_ai_title"
BookSettings.KEY_AI_AUTHOR = "koassistant_book_ai_author"
BookSettings.KEY_SPOILER_FREE = "koassistant_book_spoiler_free"  -- true | false | nil(=follow global)
-- Book-info level for the generic [Context] book-info block (freeform Send + include_book_context
-- actions). "none" | "basic" (title+author) | "full" (+position) | nil(=follow global).
BookSettings.KEY_BOOK_INFO = "koassistant_book_info_level"
-- Per-book quiz overrides. Sparse table; each field nil = follow global:
--   enabled (true|false; suppress-only — can't force-on a globally-disabled chapter quiz),
--   count, difficulty, mc, sa, essay, chapter_depth, min_pages, min_minutes.
BookSettings.KEY_QUIZ = "koassistant_book_quiz"

--- Resolve the effective book-info level for a book: per-book override > global default ("basic").
-- @return "none" | "basic" | "full"
function BookSettings.resolveBookInfoLevel(doc_settings, features)
    local per_book = doc_settings and doc_settings:readSetting(BookSettings.KEY_BOOK_INFO)
    if per_book ~= nil then return per_book end
    return (features and features.book_info_in_chat) or "basic"
end

--- THE spoiler-posture resolver (Track 36 / spoiler_posture_plan.md §2): one
-- rule, two layers. Request layer (prompts, tool reading clamps, scope
-- checks): session chip > research mode > finished book > per-book override
-- > global. Mechanical layer (X-Ray installs/promotion): the same MINUS the
-- session chip — by design a per-chat toggle must never silently reinstall a
-- different X-Ray version for the book, so opts.session is ignored there.
-- Research mode (book override > global; the 50(g) rule, device-confirmed
-- 2026-08-05) disables spoiler protection OUTRIGHT for the whole book — even
-- over an explicit per-book spoiler override; escape hatch = per-book
-- research OFF, which re-enables the spoiler layers. DOI auto-detected
-- research is deliberately NOT consulted (a request-time signal, not a
-- standing setting).
-- A book marked Finished (KOReader's summary.status == "complete") stands
-- protection down the same way (maintainer 2026-08-11): there is nothing
-- left to protect, so a re-reader can flip around without touching their
-- spoiler settings. The stored settings stay untouched — un-finishing the
-- book restores whatever was set. Like research this beats the per-book
-- override (it is a factual signal, not a preference); the session chip
-- still wins in the request layer (an explicit "No spoilers" tap is
-- honored even on a finished book).
-- @param doc_settings table|nil The book's DocSettings (live instance for open books)
-- @param features table|nil
-- @param opts table|nil { layer = "request" (default) | "mechanical",
--   session = true|false|nil — the Spoiler chip's per-chat value, if the
--   call site has one }
-- @return table { protected = boolean, reason = "session"|"research"|
--   "finished"|"book"|"global"|"default", layer = the resolved layer }.
--   "default" = nothing set anywhere (the schema default: protection ON
--   since the §4.3 flip) — kept distinct from an explicit global value so
--   the flip lives in exactly one branch.
function BookSettings.resolveSpoilerPosture(doc_settings, features, opts)
    opts = opts or {}
    local layer = opts.layer == "mechanical" and "mechanical" or "request"
    if layer == "request" and opts.session ~= nil then
        return { protected = opts.session == true, reason = "session", layer = layer }
    end
    if BookSettings.resolveResearch(doc_settings, features) then
        return { protected = false, reason = "research", layer = layer }
    end
    local summary = doc_settings and doc_settings:readSetting("summary")
    if summary and summary.status == "complete" then
        return { protected = false, reason = "finished", layer = layer }
    end
    local book = doc_settings and doc_settings:readSetting(BookSettings.KEY_SPOILER_FREE)
    if book ~= nil then
        return { protected = book == true, reason = "book", layer = layer }
    end
    local global = features and features.spoiler_free_chat
    if global ~= nil then
        return { protected = global == true, reason = "global", layer = layer }
    end
    return { protected = true, reason = "default", layer = layer }
end

--- Effective spoiler protection for a book — the REQUEST layer of
-- resolveSpoilerPosture without a session value (the Spoiler chip stays the
-- caller's concern at sites that carry one). Research mode disables
-- protection here too — the §2 unification consequence: the chat nudge and
-- the tool reading clamp now follow the same rule as X-Ray posture.
-- @return boolean
function BookSettings.resolveSpoilerFree(doc_settings, features)
    return BookSettings.resolveSpoilerPosture(doc_settings, features).protected
end

--- The X-Ray version machinery's view of the posture (xray_ecosystem_plan.md
-- 50(f)+(g)) — the MECHANICAL layer of resolveSpoilerPosture: session/per-chat
-- toggles are never consulted (posture is a persisted-settings decision that
-- outlives any one request).
-- @param doc_settings table|nil The book's DocSettings (live instance for open books)
-- @param features table|nil
-- @return string posture "track" (promotion follows the reading position) |
--   "full" (the newest built version installs as soon as it is ready)
-- @return string reason "research" | "finished" | "book" | "global" (the
--   resolver's "default" collapses into "global" — callers only label
--   layers, and nothing-set IS the global state)
function BookSettings.resolveXrayPosture(doc_settings, features)
    local p = BookSettings.resolveSpoilerPosture(doc_settings, features, { layer = "mechanical" })
    local reason = p.reason == "default" and "global" or p.reason
    return p.protected and "track" or "full", reason
end

--- Effective domain for a book: book override > global selected_domain; the
-- "_none" sentinel is an explicit no-domain override for the book. Pure. The
-- ACTION layer (prompt.domain pins) stays at the call sites that have an
-- action. (Consolidation round P1 — this fold used to be re-derived inline at
-- every consumer.)
-- @param doc_settings table|nil
-- @param features table|nil the features table holding selected_domain
-- @return string|nil effective domain id
-- @return string|nil layer "book" | "global" | nil — nil = no domain anywhere;
--   "book" with a nil id = the explicit no-domain override
function BookSettings.resolveDomain(doc_settings, features)
    local book = doc_settings and doc_settings:readSetting(BookSettings.KEY_DOMAIN) or nil
    if book == "_none" then return nil, "book" end
    if book ~= nil then return book, "book" end
    local global = features and features.selected_domain or nil
    if global ~= nil then return global, "global" end
    return nil, nil
end

--- Effective research mode for a book: book override > per-request DOI
-- auto-detection (opts.doi — only callers holding a request know it; chips,
-- pickers and the spoiler posture deliberately omit it) > global. Pure boolean.
function BookSettings.resolveResearch(doc_settings, features, opts)
    local book = doc_settings and doc_settings:readSetting(BookSettings.KEY_RESEARCH)
    if book ~= nil then return book == true end
    if opts and opts.doi then return true end
    return (features and features.research_mode) == true
end

-- Per-book AI Book Tools posture ("off" | "manual" | "auto" | nil = follow global).
BookSettings.KEY_TOOLS = "koassistant_book_tools"

-- Per-book Automatic X-Ray (xray_ecosystem_plan.md §7 P1): "on" | "off" | nil =
-- follow global. "on" = the full bundle for THIS book — auto-create + auto-update
-- (+ promotion, which is unconditional anyway) — standalone, no global master
-- needed. Legacy boolean true (the pre-tri-state double-opt-in) is honored as
-- "on" only when the one-time migration recorded the old master as enabled —
-- with the old master off, stored opt-ins were inert and must not re-activate.
BookSettings.KEY_XRAY_AUTO = "koassistant_book_xray_auto"
-- Round 19: once-per-book stamp for the first-auto-fire coverage ask (set by the
-- ask itself and by every EXPLICIT follow opt-in — picker On, Create-form follow
-- pick, the P4 offer — which already answer the question the ask would pose)
BookSettings.KEY_XRAY_COVERAGE_ASKED = "koassistant_book_xray_coverage_asked"
-- Round 21 (unified checkpoint engine): per-book coverage GOAL bounding the
-- checkpoint grid — a ratio for section-end targets; nil = whole book. Written
-- by the Create form's "as I read" pick under section-end coverage and by the
-- Extend-coverage chooser; the auto scheduler idles once the goal is reached.
BookSettings.KEY_XRAY_GOAL = "koassistant_book_xray_goal"
-- Device round 2026-08-05 (item 50 round 5): mechanical promotion hold —
-- "position" pins checkpoint promotion to position-following while the
-- spoiler posture is FULL, for readers who want X-Rays by position without
-- spoiler protection (prompts and build cadence untouched). Set by deliberate
-- below-newest installs/switches, cleared by deliberate newest/complete
-- installs and by X-Ray deletion.
BookSettings.KEY_XRAY_PROMOTION = "koassistant_book_xray_promotion"
-- Spacing slice (2026-08-14): per-book checkpoint spacing (a ratio, e.g. 0.10).
-- nil = the pages-per-rung formula (XrayAuto.ladderSpacingFor). Written by the
-- authoring form's spacing row and the first-spend coverage ask; read through
-- AskGPT:_xrayLadderSpacing at every planning site. A change only affects
-- checkpoints planned from now on — plans always start at the ladder top, so
-- built rungs keep their spans by construction.
BookSettings.KEY_XRAY_SPACING = "koassistant_book_xray_spacing"
-- X-Ray marking overrides (2026-08-15 device round, maintainer: "changing
-- density, visual stuff, from the X-Ray popup should be book settings"): the
-- popup's Marking quick settings write THESE (nil = follow global); the
-- Settings menu rows stay the global defaults.
BookSettings.KEY_XRAY_MARKING = "koassistant_book_xray_marking"                    -- true | false | nil
BookSettings.KEY_XRAY_MARKING_DENSITY = "koassistant_book_xray_marking_density"    -- "all"|"first"|"10"|"25"|"once" | nil
BookSettings.KEY_XRAY_MARKING_FAMILIES = "koassistant_book_xray_marking_families"  -- "all"|"people"|"people_places" | nil
BookSettings.KEY_XRAY_MARKING_TAP = "koassistant_book_xray_marking_tap"            -- true | false | nil
BookSettings.KEY_XRAY_AHEAD = "koassistant_book_xray_ahead"                        -- true | false | nil (Upcoming Entities peek)
-- Round 5 (2026-08-16, maintainer: "yes per book"): the two lookup-side
-- settings join the per-book pattern after all. The card key folds the global
-- landing+style PAIR into one three-way value.
BookSettings.KEY_XRAY_INTERCEPT = "koassistant_book_xray_intercept"                -- true | false | nil (matching selections open entries)
BookSettings.KEY_XRAY_CARD = "koassistant_book_xray_card"                          -- "footnote"|"popup"|"full" | nil (exact hits open)
-- B269 (2026-08-25): what the card SHOWS — non-ahead entries whole or first
-- sentence; ahead (upcoming) entries name-only-tap-to-show or one sentence.
BookSettings.KEY_XRAY_CARD_LENGTH = "koassistant_book_xray_card_length"            -- "full"|"sentence" | nil
BookSettings.KEY_XRAY_AHEAD_CARD = "koassistant_book_xray_ahead_card"              -- "name"|"entry" | nil
-- Presets session (v0.21): categories a NEW X-Ray tracks — csv of group ids
-- ("people,events"; canonical order people,places,ideas,terms,events), nil =
-- full. The preference for future creates/rebuilds only: an existing lineage
-- follows its cache STAMP (xray_categories on the entry), never this key —
-- categories cannot be added incrementally (the text is only read once).
BookSettings.KEY_XRAY_CATEGORIES = "koassistant_book_xray_categories"
--- Effective X-Ray marking & lookup config for a book: book override > global
--- > default. Pure. Read pattern must match the schema defaults (marking ON,
--- tap ON, density "10", families "all", ahead ON, intercept ON, card
--- "footnote"). `card` folds the global xray_card_landing/_style PAIR into one
--- three-way value ("footnote" | "popup" | "full").
--- B269: `card_length` ("full" default | "sentence") and `ahead_card`
--- ("name" default | "entry") ride the same pattern.
--- @return table { enabled, density, families, tap, ahead, intercept, card,
---   card_length, ahead_card, has_override }
function BookSettings.resolveXrayMarking(doc_settings, features)
    features = features or {}
    -- No and/or chain here: it would fold an explicit book-level FALSE into
    -- nil and let the global leak through (the classic tri-state pitfall)
    local function rd(key)
        if doc_settings and doc_settings.readSetting then
            return doc_settings:readSetting(key)
        end
        return nil
    end
    local b_on = rd(BookSettings.KEY_XRAY_MARKING)
    local b_dens = rd(BookSettings.KEY_XRAY_MARKING_DENSITY)
    local b_fam = rd(BookSettings.KEY_XRAY_MARKING_FAMILIES)
    local b_tap = rd(BookSettings.KEY_XRAY_MARKING_TAP)
    local b_ahead = rd(BookSettings.KEY_XRAY_AHEAD)
    local b_int = rd(BookSettings.KEY_XRAY_INTERCEPT)
    local b_card = rd(BookSettings.KEY_XRAY_CARD)
    local b_len = rd(BookSettings.KEY_XRAY_CARD_LENGTH)
    local b_acard = rd(BookSettings.KEY_XRAY_AHEAD_CARD)
    local enabled
    if b_on ~= nil then
        enabled = b_on ~= false
    else
        enabled = features.xray_marking ~= false
    end
    local tap
    if b_tap ~= nil then
        tap = b_tap ~= false
    else
        tap = features.xray_marking_tap ~= false
    end
    local ahead
    if b_ahead ~= nil then
        ahead = b_ahead ~= false
    else
        ahead = features.xray_show_ahead_entities ~= false
    end
    local intercept
    if b_int ~= nil then
        intercept = b_int ~= false
    else
        intercept = features.xray_selection_intercept ~= false
    end
    local card
    if b_card == "footnote" or b_card == "popup" or b_card == "full" then
        card = b_card
    elseif features.xray_card_landing == false then
        card = "full"
    elseif features.xray_card_style == "popup" then
        card = "popup"
    else
        card = "footnote"
    end
    return {
        enabled = enabled,
        density = b_dens or features.xray_marking_density or "10",
        families = b_fam or features.xray_marking_families or "all",
        tap = tap,
        ahead = ahead,
        intercept = intercept,
        card = card,
        card_length = (b_len == "sentence" or b_len == "full") and b_len
            or (features.xray_card_length == "full" and "full" or "sentence"),
        ahead_card = (b_acard == "entry" or b_acard == "name") and b_acard
            or (features.xray_ahead_card == "entry" and "entry" or "name"),
        has_override = b_on ~= nil or b_dens ~= nil or b_fam ~= nil
            or b_tap ~= nil or b_ahead ~= nil or b_int ~= nil or b_card ~= nil
            or b_len ~= nil or b_acard ~= nil,
    }
end

--- X-Ray promotion hold. Pure.
--- @return boolean true = promotion follows the reading position for this book
function BookSettings.xrayPromotionHold(doc_settings)
    return (doc_settings and doc_settings:readSetting(BookSettings.KEY_XRAY_PROMOTION)) == "position"
end

--- Per-book checkpoint spacing override. Pure.
--- @return number|nil ratio in (0, 0.5], or nil = follow the formula
function BookSettings.xraySpacingOverride(doc_settings)
    local v = doc_settings and tonumber(doc_settings:readSetting(BookSettings.KEY_XRAY_SPACING))
    if v and v > 0.005 and v <= 0.5 then return v end
    return nil
end

--- Per-book Automatic X-Ray override. Pure.
--- @return string|nil "on" | "off" | nil (= follow global)
function BookSettings.xrayAutoOverride(doc_settings, features)
    local v = doc_settings and doc_settings:readSetting(BookSettings.KEY_XRAY_AUTO)
    if v == "on" or v == "off" then return v end
    if v == true and features and features._xray_auto_legacy_optin == true then
        return "on"
    end
    return nil
end

--- Effective X-Ray automation for a book. Per-book "on" bundles auto-create
--- (the one-switch directive); follow-global books need the global create
--- sub-toggle on top of the global master. Pure.
--- @return boolean auto, boolean create_allowed, string|nil override
function BookSettings.resolveXrayAuto(doc_settings, features)
    local ov = BookSettings.xrayAutoOverride(doc_settings, features)
    if ov == "on" then return true, true, ov end
    if ov == "off" then return false, false, ov end
    local f = features or {}
    local auto = f.xray_auto_update == true
    return auto, auto and f.xray_auto_create == true, nil
end

--- Row/chip label for the current per-book Automatic X-Ray state. Pure.
function BookSettings.xrayAutoLabel(doc_settings, features)
    local ov = BookSettings.xrayAutoOverride(doc_settings, features)
    if ov == "on" then return _("On") end
    if ov == "off" then return _("Off") end
    local global_on = features and features.xray_auto_update == true
    return T(_("Follow global (%1)"), global_on and _("On") or _("Off"))
end


--- Map a stored tools value — new boolean or legacy posture string — onto the
-- binary model (2026-08-12 collapse, maintainer: "no reason to have separate
-- OFF vs Auto/Manual; function like web search"). Sidecar files are never
-- mass-migrated, so legacy per-book strings live on and MUST keep resolving:
-- "auto"/true = tools default ON; "manual"/"off"/false = default OFF (the old
-- hard-off master switch is gone — the chip can always flip a session on).
-- nil (and anything unrecognized) = no opinion.
local function toolsValueOn(v)
    if v == true or v == "auto" then return true end
    if v == false or v == "manual" or v == "off" then return false end
    return nil
end

--- Effective AI Book Tools default for a book: per-book override > global
-- `enable_book_tools` (default OFF since v0.21 — maintainer 2026-08-17, off
-- until retrieval quality matures; explicit values and legacy "auto" picks
-- keep resolving ON) > legacy `tools_posture` read-through for configs the
-- migration hasn't touched. Pure boolean: true = the Tools chip starts ON.
function BookSettings.resolveBookTools(doc_settings, features)
    local per_book = toolsValueOn(
        doc_settings and doc_settings:readSetting(BookSettings.KEY_TOOLS))
    if per_book ~= nil then return per_book end
    if features then
        if features.enable_book_tools ~= nil then
            return features.enable_book_tools ~= false
        end
        local legacy = toolsValueOn(features.tools_posture)
        if legacy ~= nil then return legacy end
    end
    return false
end

-- Per-book domain ("<domain id>" | "_none" = explicitly no domain | nil = follow global)
-- and research mode (true | false | nil = follow global). Constants only — resolution
-- stays with the callers (the domain chain layers action > book > global and handles
-- the "_none" sentinel in place).
BookSettings.KEY_DOMAIN = "koassistant_book_domain"
BookSettings.KEY_RESEARCH = "koassistant_book_research_mode"

-- Per-book Background (book_background_plan.md): the reader's standing note about THIS
-- book — why they're reading it, what stance they bring, what the metadata gets wrong.
-- Rides the unified system prompt next to behavior/domain, so it reaches every entry
-- point (direct actions included), unlike the session-scoped Attach note.
BookSettings.KEY_BACKGROUND = "koassistant_book_background"

-- Hard cap: the Background rides EVERY request for this book (cached on Anthropic,
-- uncached elsewhere), so a pasted essay must not silently inflate every call.
BookSettings.BACKGROUND_MAX_CHARS = 2000

--- Read this book's Background, trimmed and capped. Pure.
-- Over-cap text is cut by the Attach engine's truncate (UTF-8-safe, snaps to the
-- previous line break) — its truncation NOTE is deliberately dropped: this is the
-- reader's own standing note, not an attachment, and a "[truncated]" marker in the
-- system prompt would read as instruction text.
-- @return string|nil  nil when unset/blank (never an empty string)
function BookSettings.getBackground(doc_settings)
    local v = doc_settings and doc_settings:readSetting(BookSettings.KEY_BACKGROUND)
    if type(v) ~= "string" then return nil end
    v = v:match("^%s*(.-)%s*$")
    if v == "" then return nil end
    if #v > BookSettings.BACKGROUND_MAX_CHARS then
        v = require("koassistant_attachments").truncate(
            v, BookSettings.BACKGROUND_MAX_CHARS, "head")
    end
    return v
end

-- Per-book web-search override (true | false | nil = follow global).
BookSettings.KEY_WEB_SEARCH = "koassistant_book_web_search"

--- Raw per-book web-search override (tri-state). Callers layer this between the
-- per-chat toggle and the global default.
-- @return true | false | nil
function BookSettings.webSearchOverride(doc_settings)
    local v = doc_settings and doc_settings:readSetting(BookSettings.KEY_WEB_SEARCH)
    if v == nil then return nil end
    return v == true
end

--- Resolve effective web-search state for a book: per-book override > global
-- enable_web_search (opt-in, schema default false — check pattern matches) >
-- the provider's NATIVE default (optional 3rd arg: Perplexity searches unless
-- told not to — disable_search probed real 2026-08-14 — so an untouched global
-- resolves ON there, keeping out-of-box behavior and making the Web chip
-- truthful; every other provider stays off). The per-chat toggle is the
-- caller's concern (mirrors resolveSpoilerFree).
-- @return boolean
function BookSettings.resolveWebSearch(doc_settings, features, provider)
    local per_book = BookSettings.webSearchOverride(doc_settings)
    if per_book ~= nil then return per_book end
    local global = features and features.enable_web_search
    if global ~= nil then return global == true end
    return provider == "perplexity"
end

-- Per-book overrides for the two "how much work" dials (nil = follow global). Surfaced
-- on the Tools/Web chip holds (showEffortPicker) so cost/latency is tunable per book or
-- globally without diving into Advanced settings — buildUnifiedRequestConfig bakes the
-- resolved value into config.features so BookToolRunner.budgetFor and
-- ModelConstraints.webSearchEffort pick it up unchanged.
BookSettings.KEY_TOOL_EFFORT = "koassistant_book_tool_effort"   -- "quick"|"standard"|"thorough"
BookSettings.KEY_WEB_EFFORT = "koassistant_book_web_effort"     -- "light"|"standard"|"thorough"

--- Resolve effective book-tools lookup effort: per-book override > global
-- features.tool_lookup_effort > "standard" (schema default).
-- @return "quick" | "standard" | "thorough"
function BookSettings.resolveToolEffort(doc_settings, features)
    local valid = { quick = true, standard = true, thorough = true }
    local per_book = doc_settings and doc_settings:readSetting(BookSettings.KEY_TOOL_EFFORT)
    if valid[per_book] then return per_book end
    local global = features and features.tool_lookup_effort
    if valid[global] then return global end
    return "standard"
end

--- Resolve effective web-search depth: per-book override > global
-- features.web_search_effort > "standard". Mirrors resolveToolEffort.
-- @return "light" | "standard" | "thorough"
function BookSettings.resolveWebEffort(doc_settings, features)
    local valid = { light = true, standard = true, thorough = true }
    local per_book = doc_settings and doc_settings:readSetting(BookSettings.KEY_WEB_EFFORT)
    if valid[per_book] then return per_book end
    local global = features and features.web_search_effort
    if valid[global] then return global end
    return "standard"
end

--- Translated labels for the effort values (shared by the chip-hold rows + the picker).
function BookSettings.toolEffortLabel(v)
    if v == "quick" then return _("Quick")
    elseif v == "thorough" then return _("Thorough") end
    return _("Standard")
end
function BookSettings.webEffortLabel(v)
    if v == "light" then return _("Light")
    elseif v == "thorough" then return _("Thorough") end
    return _("Standard")
end

-- Per-book ⚡ Quick Answer default (true | false | nil = follow global). Governs
-- the chip's STARTING state on a fresh chat dialog (controls parity §8c.7 —
-- tools-posture-style default, decided 2026-07-20; the session chip wins once
-- touched, exactly like tools "auto") AND direct entries of accept_quick_answer
-- actions (maintainer 2026-08-11: the default touches all receptive requests
-- regardless of entry point — seeded in handlePredefinedPrompt's direct-entry
-- guard).
BookSettings.KEY_QUICK_ANSWER = "koassistant_book_quick_answer"

--- Resolve the ⚡ Quick Answer DEFAULT: per-book override > global
-- quick_answer_default (opt-in, schema default false).
-- @return boolean
function BookSettings.resolveQuickAnswerDefault(doc_settings, features)
    local v = doc_settings and doc_settings:readSetting(BookSettings.KEY_QUICK_ANSWER)
    if v ~= nil then return v == true end
    return (features and features.quick_answer_default) == true
end

-- Per-book surrounding-context overrides (surrounding_context_plan.md §2): a mode
-- string ("none" | "sentence" | "paragraph" | "characters") or nil = follow global.
-- "none" = explicitly off for this book. Sizes (chars/paragraphs) stay global.
-- Two parallel channels: highlight requests (ambient) and dictionary lookups.
BookSettings.KEY_HIGHLIGHT_CONTEXT = "koassistant_book_highlight_context"
BookSettings.KEY_DICTIONARY_CONTEXT = "koassistant_book_dictionary_context"

local VALID_CONTEXT_MODES = { none = true, sentence = true, paragraph = true, characters = true }

--- Resolve the effective ambient surrounding-context mode for highlight requests:
-- per-book override > global highlight_context_mode > "none" (the schema default —
-- ambient is opt-in; matches the check-pattern rule). Pure. Unknown stored values
-- fall through so a corrupt sidecar value can't wedge the feature.
-- @return "none" | "sentence" | "paragraph" | "characters"
function BookSettings.resolveHighlightContext(doc_settings, features)
    local per_book = doc_settings and doc_settings:readSetting(BookSettings.KEY_HIGHLIGHT_CONTEXT)
    if VALID_CONTEXT_MODES[per_book] then return per_book end
    local global = features and features.highlight_context_mode
    if VALID_CONTEXT_MODES[global] then return global end
    return "none"
end

--- Resolve the effective dictionary-context mode (the {context_section} channel):
-- per-book override > global dictionary_context_mode > "sentence". Pure.
-- The default lives here rather than in the schema (the settings entry is a submenu
-- with no `path`, so applyDefaults drops the key on reset and this literal IS the
-- post-reset default). Three other sites hardcode it for display — main.lua's radio
-- checked_func, the schema submenu's text_func, and the "Follow global" label below;
-- all four must move together or Settings will show a mode it isn't sending.
-- Flipped "none" -> "sentence" by defaults sweep D1 (2026-07-26): the sentence is
-- already extracted on every dictionary path, it was just withheld until the reader
-- pressed Ctx. The Ctx button stays as the per-lookup toggle, now turn-it-OFF.
-- @return "none" | "sentence" | "paragraph" | "characters"
function BookSettings.resolveDictionaryContext(doc_settings, features)
    local per_book = doc_settings and doc_settings:readSetting(BookSettings.KEY_DICTIONARY_CONTEXT)
    if VALID_CONTEXT_MODES[per_book] then return per_book end
    local global = features and features.dictionary_context_mode
    if VALID_CONTEXT_MODES[global] then return global end
    return "sentence"
end

--- Translated label for a context-mode value (Book Settings rows + pickers).
function BookSettings.contextModeLabel(v)
    if v == "none" then return _("None")
    elseif v == "sentence" then return _("Sentence")
    elseif v == "paragraph" then return _("Paragraph(s)")
    elseif v == "characters" then return _("Characters") end
    return _("Follow global")
end

--- Resolve effective quiz settings for a book: per-book field > global > built-in default.
-- Pure (no I/O beyond the one sidecar read). The quiz-instruction builder consumes the
-- count/difficulty/mc/sa/essay/chapter_depth fields; the chapter-end trigger consumes
-- enabled (suppress-only), min_pages, and min_minutes. Booleans collapse the global's "nil = on" rule.
-- @return table { count, difficulty, mc, sa, essay, chapter_depth, enabled, min_pages, min_minutes }
function BookSettings.resolveQuiz(doc_settings, features)
    features = features or {}
    local bq = (doc_settings and doc_settings:readSetting(BookSettings.KEY_QUIZ)) or {}
    -- For required fields: book value, else global, else built-in default.
    local function pick(book_val, global_val, default)
        if book_val ~= nil then return book_val end
        if global_val ~= nil then return global_val end
        return default
    end
    return {
        count = pick(bq.count, features.quiz_question_count, 8),
        difficulty = pick(bq.difficulty, features.quiz_difficulty, "medium"),
        mc = pick(bq.mc, features.quiz_mc_enabled, true),
        sa = pick(bq.sa, features.quiz_short_answer_enabled, true),
        essay = pick(bq.essay, features.quiz_essay_enabled, true),
        chapter_depth = pick(bq.chapter_depth, features.quiz_chapter_depth, 2),
        -- Trigger-gate fields: enabled is suppress-only (raw per-book value, no global fallback
        -- here — the global enable gate is checked separately, before this is read);
        -- min_pages / min_minutes fall back to the global thresholds, then the schema defaults
        -- (5 pages / 3 min) — NOT 0 — so the gates are active out of the box (schema defaults
        -- aren't persisted to disk). An explicit 0 still means "no minimum" (0 is truthy in Lua,
        -- so it isn't replaced by the default).
        enabled = bq.enabled,
        min_pages = pick(bq.min_pages, features.quiz_min_chapter_pages, 5),
        min_minutes = pick(bq.min_minutes, features.quiz_min_chapter_time, 3),
    }
end

--- Set one field of the sparse per-book quiz table (nil clears it). Shallow-copies so a shared
-- reference isn't mutated, and drops an emptied table so a reset book carries no override.
-- Shared by the Book Settings quiz screen and the chapter-quiz popup's "Not for this book".
function BookSettings.setQuizField(doc_settings, field, value)
    if not doc_settings then return end
    local new = {}
    for k, v in pairs(doc_settings:readSetting(BookSettings.KEY_QUIZ) or {}) do new[k] = v end
    new[field] = value
    if next(new) == nil then new = nil end
    doc_settings:saveSetting(BookSettings.KEY_QUIZ, new)
    doc_settings:flush()
end

-- Per-book target-language overrides (string language id, or nil/"" = follow global).
BookSettings.KEY_TRANSLATION_LANG = "koassistant_book_translation_language"
BookSettings.KEY_DICTIONARY_LANG = "koassistant_book_dictionary_language"
-- Per-book MAIN AI response language (the "Always respond in X" system-prompt directive that
-- applies to every action — distinct from the translate/dictionary target languages above).
BookSettings.KEY_RESPONSE_LANG = "koassistant_book_response_language"

--- Fold per-book translation/dictionary language overrides into a language-resolver config
-- (the table passed to SystemPrompts.getEffective*Language). Pure: returns the input
-- unchanged when there's no override, else a shallow copy with the fields overridden.
-- A translation override also forces translation_use_primary=false so the resolver actually
-- uses the override instead of the user's primary language.
-- @param config table  the resolver config { translation_language, dictionary_language, ... }
-- @param doc_settings table|nil
-- @return table
function BookSettings.applyLanguageOverride(config, doc_settings)
    if not doc_settings then return config end
    local t = doc_settings:readSetting(BookSettings.KEY_TRANSLATION_LANG)
    local d = doc_settings:readSetting(BookSettings.KEY_DICTIONARY_LANG)
    local has_t = t ~= nil and t ~= ""
    local has_d = d ~= nil and d ~= ""
    if not has_t and not has_d then return config end
    local c = {}
    for k, v in pairs(config) do c[k] = v end
    if has_t then
        c.translation_use_primary = false
        c.translation_language = t
    end
    if has_d then
        c.dictionary_language = d
    end
    return c
end

--- Fold a per-book MAIN response-language override into a buildUnifiedSystem language config
-- ({ interaction_languages, user_languages, primary_language }). Pure: returns the input
-- unchanged when there's no override, else a shallow copy. parseUserLanguages only honours a
-- primary override that's already in the list, so the override language is prepended (deduped)
-- AND set as primary — the user's other languages stay in the "understands" list, preserving
-- the same switch-on-explicit behaviour as the global multi-language setting.
-- @param config table { interaction_languages, user_languages, primary_language }
-- @param doc_settings table|nil
-- @return table
function BookSettings.applyResponseLanguageOverride(config, doc_settings)
    if not doc_settings then return config end
    local lang = doc_settings:readSetting(BookSettings.KEY_RESPONSE_LANG)
    if lang == nil or lang == "" then return config end
    local c = {}
    for k, v in pairs(config) do c[k] = v end
    local list = { lang }
    local existing = config.interaction_languages or config.user_languages
    if type(existing) == "table" then
        for _i, l in ipairs(existing) do
            if l ~= lang and l ~= "" then table.insert(list, l) end
        end
    elseif type(existing) == "string" and existing ~= "" then
        for l in existing:gmatch("([^,]+)") do
            local trimmed = l:match("^%s*(.-)%s*$")
            if trimmed ~= "" and trimmed ~= lang then table.insert(list, trimmed) end
        end
    end
    c.interaction_languages = list
    c.primary_language = lang
    return c
end

-- Per-book PRIVACY overrides (2026-08-02): tri-state sidecar keys — true = allow
-- for this book, false = deny for this book, nil = follow global. Enforcement
-- semantics (koassistant_context_extractor.lua + the notebook/pre-flight/tools
-- gates): a per-book DENY beats everything including trusted providers (most
-- specific intent — "never share this book's data"); a per-book ALLOW satisfies
-- the GLOBAL gate only, so per-action flags still apply (double-gating holds).
BookSettings.KEY_HIGHLIGHTS_SHARING = "koassistant_book_highlights_sharing"
BookSettings.KEY_ANNOTATIONS_SHARING = "koassistant_book_annotations_sharing"
BookSettings.KEY_NOTEBOOK_SHARING = "koassistant_book_notebook_sharing"
BookSettings.KEY_TEXT_EXTRACTION = "koassistant_book_text_extraction"

--- Raw per-book privacy overrides. Pure.
-- @return table { highlights = tri, annotations = tri, notebook = tri, book_text = tri }
function BookSettings.getPrivacyOverrides(doc_settings)
    if not doc_settings then return {} end
    return {
        highlights = doc_settings:readSetting(BookSettings.KEY_HIGHLIGHTS_SHARING),
        annotations = doc_settings:readSetting(BookSettings.KEY_ANNOTATIONS_SHARING),
        notebook = doc_settings:readSetting(BookSettings.KEY_NOTEBOOK_SHARING),
        book_text = doc_settings:readSetting(BookSettings.KEY_TEXT_EXTRACTION),
    }
end

--- Effective per-book privacy overrides, with the same implication the globals
-- have: allowing annotations implies highlights; denying highlights denies
-- annotations too (the promise is "no highlighted text from this book"). Pure.
-- @return table { highlights = tri, annotations = tri, notebook = tri, book_text = tri }
function BookSettings.effectivePrivacyOverrides(doc_settings)
    local raw = BookSettings.getPrivacyOverrides(doc_settings)
    -- Strict booleans only: a corrupt/hand-edited sidecar value (e.g. the string
    -- "off") must read as "follow global", never as a truthy ALLOW (fail-closed).
    local function tri(v)
        if v == true then return true elseif v == false then return false end
        return nil
    end
    local out = { notebook = tri(raw.notebook), book_text = tri(raw.book_text) }
    if raw.highlights == false then out.highlights = false
    elseif raw.highlights == true or raw.annotations == true then out.highlights = true end
    if raw.annotations == false or raw.highlights == false then out.annotations = false
    elseif raw.annotations == true then out.annotations = true end
    return out
end

-- Every DocSettings sidecar key this module owns. Single source of truth for the
-- "reset book settings" action, the customized-count indicator, and (later) Track 33's
-- storage registry. Keep in sync when adding a per-book setting.
BookSettings.SIDECAR_KEYS = {
    BookSettings.KEY_DOMAIN,
    BookSettings.KEY_RESEARCH,
    BookSettings.KEY_BACKGROUND,
    BookSettings.KEY_SPOILER_FREE,
    BookSettings.KEY_BOOK_INFO,
    BookSettings.KEY_AI_TITLE,
    BookSettings.KEY_AI_AUTHOR,
    BookSettings.KEY_QUIZ,
    BookSettings.KEY_TRANSLATION_LANG,
    BookSettings.KEY_DICTIONARY_LANG,
    BookSettings.KEY_RESPONSE_LANG,
    BookSettings.KEY_TOOLS,
    BookSettings.KEY_WEB_SEARCH,
    BookSettings.KEY_HIGHLIGHT_CONTEXT,
    BookSettings.KEY_DICTIONARY_CONTEXT,
    BookSettings.KEY_XRAY_AUTO,
    BookSettings.KEY_XRAY_GOAL,
    BookSettings.KEY_XRAY_PROMOTION,
    BookSettings.KEY_XRAY_SPACING,
    BookSettings.KEY_XRAY_MARKING,
    BookSettings.KEY_XRAY_MARKING_DENSITY,
    BookSettings.KEY_XRAY_MARKING_FAMILIES,
    BookSettings.KEY_XRAY_MARKING_TAP,
    BookSettings.KEY_XRAY_AHEAD,
    BookSettings.KEY_XRAY_INTERCEPT,
    BookSettings.KEY_XRAY_CARD,
    BookSettings.KEY_XRAY_CARD_LENGTH,
    BookSettings.KEY_XRAY_AHEAD_CARD,
    BookSettings.KEY_XRAY_CATEGORIES,
    -- (KEY_XRAY_COVERAGE_ASKED is deliberately NOT here: a stamp, not an
    -- override — it must not count as "customized" nor block on reset;
    -- registered as its own storage-registry entry like the last-opened stamp)
    BookSettings.KEY_QUICK_ANSWER,
    BookSettings.KEY_TOOL_EFFORT,
    BookSettings.KEY_WEB_EFFORT,
    BookSettings.KEY_HIGHLIGHTS_SHARING,
    BookSettings.KEY_ANNOTATIONS_SHARING,
    BookSettings.KEY_NOTEBOOK_SHARING,
    BookSettings.KEY_TEXT_EXTRACTION,
}

--- Count how many per-book settings deviate from the global defaults (any non-nil key).
-- @return number
function BookSettings.countCustomized(doc_settings)
    if not doc_settings then return 0 end
    local n = 0
    for _i, key in ipairs(BookSettings.SIDECAR_KEYS) do
        if doc_settings:readSetting(key) ~= nil then n = n + 1 end
    end
    return n
end

--- Clear every per-book override so this book follows the global defaults again.
function BookSettings.resetBook(doc_settings)
    if not doc_settings then return end
    require("koassistant_logger").dbg("KOAssistant BookSettings: clearing all",
        #BookSettings.SIDECAR_KEYS, "per-book overrides")
    for _i, key in ipairs(BookSettings.SIDECAR_KEYS) do
        doc_settings:saveSetting(key, nil)
    end
    doc_settings:flush()
end

--- Read the per-book AI title/author overrides (what the AI sees for this book).
-- @return title, author  -- each: nil (use metadata) | "" (send empty) | string (custom)
function BookSettings.getMetadataOverride(doc_settings)
    if not doc_settings then return nil, nil end
    return doc_settings:readSetting(BookSettings.KEY_AI_TITLE),
           doc_settings:readSetting(BookSettings.KEY_AI_AUTHOR)
end

--- Apply the per-book AI title/author override to a book_metadata table.
-- Returns a NEW table when an override exists (never mutates the input, which may
-- be a shared config table); returns the input unchanged when no override is set.
-- A nil override leaves the field as-is; "" sends an empty value; a string replaces it.
-- Affects only what KOAssistant sends to the AI — never KOReader's library metadata.
-- @param metadata table|nil  book_metadata { title, author, author_clause, ... }
-- @param doc_settings table|nil
-- @return table|nil
function BookSettings.applyMetadataOverride(metadata, doc_settings)
    local t, a = BookSettings.getMetadataOverride(doc_settings)
    if t == nil and a == nil then return metadata end
    local m = {}
    if metadata then for k, v in pairs(metadata) do m[k] = v end end
    if t ~= nil then m.title = t end
    if a ~= nil then
        m.author = a
        m.author_clause = (a ~= "") and (" by " .. a) or ""
    end
    return m
end

--- Resolve the DocSettings instance for a per-book target.
-- Delegates to SafeDocSettings: always the live in-memory instance when the
-- target book is the open one (avoids a stale-read/whole-file-flush clobber,
-- issue #72); a fresh disk instance only when the book is not open.
-- @return doc_settings|nil
local function resolveDocSettings(ui, document_path)
    return (require("koassistant_doc_settings").resolve(document_path, ui))
end

--- Row label for the Background setting: a one-line preview, or "not set".
-- @return string
function BookSettings.backgroundRowLabel(doc_settings)
    local v = BookSettings.getBackground(doc_settings)
    if not v then return _("not set") end
    v = v:gsub("%s+", " ")
    if #v > 28 then
        v = require("koassistant_attachments").truncate(v, 28, "head") .. "…"
    end
    return v
end

--- Background editor (book_background_plan.md §4) — the reader's standing note about
-- this book. Module-level because two surfaces open it: the Book Settings screen and
-- the Domain & Research picker (book target only).
-- The explanation lives in `description` (always visible) rather than `input_hint`
-- alone: this field reopens POPULATED, and a hint only shows on an empty field.
-- Saving an empty field clears the setting — no separate "Clear" row needed.
-- @param opts table: { plugin, ui, document_path, doc_settings, on_close }
--   doc_settings: pass an already-resolved instance (callers inside the input dialog
--   have one; avoids new upvalues there — 60-upvalue cap)
function BookSettings.showBackgroundEditor(opts)
    opts = opts or {}
    local doc_settings = opts.doc_settings or resolveDocSettings(opts.ui, opts.document_path)
    if not doc_settings then return end
    local InputDialog = require("ui/widget/inputdialog")
    local input
    local function finish()
        UIManager:close(input)
        if opts.on_close then opts.on_close() end
    end
    input = InputDialog:new{
        title = _("Background (this book)"),
        description = _("Standing context for this book: why you're reading it, the stance you bring, anything the book's own description gets wrong. It is kept with this book and sent with every request about it, alongside your domain and behavior settings. Leave empty to remove."),
        input = doc_settings:readSetting(BookSettings.KEY_BACKGROUND) or "",
        input_hint = _("e.g. \"I'm reading this biography critically; I admire its subject and I think the author has an axe to grind\"\ne.g. \"for a seminar on X\" · \"this is the Arberry translation\""),
        allow_newline = true,
        -- Multi-line by default; only text_height works for InputDialog sizing
        text_height = require("device").screen:scaleBySize(200),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() finish() end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local text = input:getInputText() or ""
                    if text:match("^%s*$") then text = nil end
                    doc_settings:saveSetting(BookSettings.KEY_BACKGROUND, text)
                    doc_settings:flush()
                    if opts.plugin and opts.plugin.updateConfigFromSettings then
                        opts.plugin:updateConfigFromSettings()
                    end
                    finish()
                end,
            },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

--- Build the Domain & Research picker button rows (pure — no I/O).
-- The caller supplies the current state and callbacks; each callback fully
-- performs its write + close/refresh.
--
-- @param state table:
--   domains         array of {id, display_name|name, ...} (already sorted)
--   has_book        bool   -- a book/doc_settings is in scope (show target toggle + book rows)
--   is_book_target  bool   -- currently editing the per-book layer (vs global)
--   book_domain     id | "_none" | nil
--   global_domain   id | nil
--   global_domain_label string|nil -- display name for the Follow-global row
--   book_research   true | false | nil
--   global_research bool
--   background_label string|nil -- preview for the Background row (book target only)
-- @param cb table (each fully performs write + close/refresh):
--   set_target(new_target)               "book" | "global"
--   pick_book_domain(id | "_none" | nil)
--   pick_global_domain(id | nil)
--   set_book_research(true | false | nil)
--   set_global_research(true | nil)
--   edit_background()                    optional -- omit to hide the Background row
--   close()
-- @param opts table|nil: { omit_close = bool }  -- caller appends its own rows + Close
-- @return table buttons (ButtonDialog rows)
function BookSettings.buildDomainResearchButtons(state, cb, opts)
    local buttons = {}
    local function dot(active) return active and "● " or "○ " end

    -- Target toggle row: [For this book] [Global] — only when a book is in scope
    if state.has_book then
        table.insert(buttons, {
            {
                text = dot(state.is_book_target) .. _("For this book"),
                callback = function()
                    if not state.is_book_target then cb.set_target("book") end
                end,
            },
            {
                text = dot(not state.is_book_target) .. _("Global"),
                callback = function()
                    if state.is_book_target then cb.set_target("global") end
                end,
            },
        })
    end

    if state.is_book_target then
        -- Book target: "Follow global (<value>)" + "None" + each domain (Q3
        -- invariant: the follow row always names the current global value)
        table.insert(buttons, {{
            text = dot(state.book_domain == nil)
                .. T(_("Follow global (%1)"),
                    state.global_domain_label or state.global_domain or _("None")),
            callback = function() cb.pick_book_domain(nil) end,
        }})
        table.insert(buttons, {{
            text = dot(state.book_domain == "_none") .. _("None"),
            callback = function() cb.pick_book_domain("_none") end,
        }})
        for _idx, domain in ipairs(state.domains) do
            local id = domain.id
            table.insert(buttons, {{
                text = dot(state.book_domain == id) .. (domain.display_name or domain.name or id),
                callback = function() cb.pick_book_domain(id) end,
            }})
        end
    else
        -- Global target (or no book open): "None" + each domain
        table.insert(buttons, {{
            text = dot(state.global_domain == nil) .. _("None"),
            callback = function() cb.pick_global_domain(nil) end,
        }})
        for _idx, domain in ipairs(state.domains) do
            local id = domain.id
            table.insert(buttons, {{
                text = dot(state.global_domain == id) .. (domain.display_name or domain.name or id),
                callback = function() cb.pick_global_domain(id) end,
            }})
        end
    end

    -- Research mode section (shares the same book/global target as domain)
    table.insert(buttons, {{
        text = "─── " .. _("Research Mode") .. " ───",
        enabled = false,
    }})

    if state.is_book_target then
        -- Book target: Follow global (<value>) / On / Off
        table.insert(buttons, {
            {
                text = dot(state.book_research == nil)
                    .. T(_("Follow global (%1)"),
                        state.global_research and _("On") or _("Off")),
                callback = function() cb.set_book_research(nil) end,
            },
            {
                text = dot(state.book_research == true) .. _("On"),
                callback = function() cb.set_book_research(true) end,
            },
            {
                text = dot(state.book_research == false) .. _("Off"),
                callback = function() cb.set_book_research(false) end,
            },
        })
    else
        -- Global target: Off / On
        table.insert(buttons, {
            {
                text = dot(not state.global_research) .. _("Off"),
                callback = function() cb.set_global_research(nil) end,
            },
            {
                text = dot(state.global_research == true) .. _("On"),
                callback = function() cb.set_global_research(true) end,
            },
        })
    end

    -- Background (book_background_plan.md §4): book target only — a standing note
    -- about THIS book has no global equivalent. Callers that don't supply
    -- cb.edit_background simply don't get the row.
    if state.is_book_target and cb.edit_background then
        table.insert(buttons, {{
            text = T(_("Background: %1"), state.background_label or _("not set")),
            callback = function() cb.edit_background() end,
        }})
    end

    if not (opts and opts.omit_close) then
        table.insert(buttons, {{
            text = _("Close"),
            id = "close",
            callback = function() cb.close() end,
        }})
    end

    return buttons
end

-- Look up a domain's display name by id (nil id → nil). Bare name, no provenance
-- suffix — used for current-state labels ("Domain: X", "Follow global (X)"); picker
-- option lists keep display_name with its "(file)"/"(custom)" suffix.
local function domainDisplayName(id, features)
    if not id then return nil end
    for _i, d in ipairs(DomainLoader.getSortedDomains(features.custom_domains or {})) do
        if d.id == id then return d.name or d.display_name or id end
    end
    return id
end

--- Domain & Research quick-picker (scope-aware: For this book / Global toggle).
-- A fast domain/research switch — used by the Quick Settings panel domain chip and the
-- input-dialog domain button. This is NOT the per-book Book Settings screen (see
-- BookSettings.show); it is the place to set the GLOBAL domain/research default.
-- @param opts table:
--   plugin          AskGPT instance (for plugin.settings + updateConfigFromSettings)
--   ui              KOReader UI (to find the open book's live doc_settings)
--   document_path   string|nil  -- explicit target book; nil = the open book
--   on_close        function|nil -- called after the dialog closes (e.g. reopen QS panel)
--   target_override "book" | "global" | nil  -- forces the editing layer (used by the toggle)
function BookSettings.showDomainResearch(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close
    local document_path = opts.document_path

    local doc_settings = resolveDocSettings(ui, document_path)
    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
    local all_domains = DomainLoader.getSortedDomains(features.custom_domains or {})

    local book_domain = doc_settings and doc_settings:readSetting(BookSettings.KEY_DOMAIN) or nil
    local book_research = doc_settings and doc_settings:readSetting(BookSettings.KEY_RESEARCH) or nil

    -- Default to "book" only when the book already has an override, else "global".
    local domain_target = opts.target_override
        or (doc_settings and (book_domain or book_research ~= nil) and "book")
        or "global"

    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    -- After a write: close, re-sync in-memory config from disk, notify caller.
    local function commit()
        closeDialog()
        if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
        -- 50(g): research flips the X-Ray spoiler posture — re-evaluate promotion
        -- now instead of waiting for a page turn (safe no-op otherwise)
        if plugin and plugin._scheduleXrayLadderPromotion then plugin:_scheduleXrayLadderPromotion() end
        if on_close then on_close() end
    end
    local function setGlobalFeature(key, value)
        local f = plugin.settings:readSetting("features") or {}
        f[key] = value
        plugin.settings:saveSetting("features", f)
        plugin.settings:flush()
    end

    local state = {
        domains = all_domains,
        has_book = doc_settings ~= nil,
        is_book_target = (doc_settings and domain_target == "book") or false,
        book_domain = book_domain,
        global_domain = features.selected_domain,
        global_domain_label = domainDisplayName(features.selected_domain, features),
        book_research = book_research,
        global_research = features.research_mode,
        background_label = doc_settings and BookSettings.backgroundRowLabel(doc_settings) or nil,
    }

    local cb = {
        set_target = function(new_target)
            closeDialog()
            BookSettings.showDomainResearch({
                plugin = plugin, ui = ui, document_path = document_path,
                on_close = on_close, target_override = new_target,
            })
        end,
        pick_book_domain = function(val)
            doc_settings:saveSetting(BookSettings.KEY_DOMAIN, val)
            doc_settings:flush()
            commit()
        end,
        pick_global_domain = function(id)
            setGlobalFeature("selected_domain", id)
            commit()
        end,
        set_book_research = function(val)
            doc_settings:saveSetting(BookSettings.KEY_RESEARCH, val)
            doc_settings:flush()
            commit()
        end,
        set_global_research = function(val)
            setGlobalFeature("research_mode", val)
            commit()
        end,
        edit_background = function()
            closeDialog()
            BookSettings.showBackgroundEditor({
                plugin = plugin, doc_settings = doc_settings,
                -- Reopen this picker on the same (book) target so the row's
                -- preview refreshes in place
                on_close = function()
                    BookSettings.showDomainResearch({
                        plugin = plugin, ui = ui, document_path = document_path,
                        on_close = on_close, target_override = "book",
                    })
                end,
            })
        end,
        close = function()
            closeDialog()
            if on_close then on_close() end
        end,
    }

    dialog = ButtonDialog:new{
        title = _("Domain & Research"),
        buttons = BookSettings.buildDomainResearchButtons(state, cb),
        -- Tap-outside behaves like Close (plugin tenet, applied across every
        -- picker in this file): the caller's surface must come back
        tap_close_callback = function() dialog = nil; if on_close then on_close() end end,
    }
    UIManager:show(dialog)
end

--- Page-based (PDF/DJVU) detection that works with or without an open document.
--- Automatic X-Ray's machinery is flowing-only, so its row and picker label the
--- setting as having no effect on such books — label, never gray (§5): the
--- stored value stays visible and editable.
local function isPageBased(ui, document_path)
    if ui and ui.document and ui.document.info then
        return ui.document.info.has_pages or false
    end
    if document_path then
        local ok, DocumentRegistry = pcall(require, "document/documentregistry")
        local prov = ok and DocumentRegistry and DocumentRegistry:getProvider(document_path)
        return (prov and prov.provider or "crengine") ~= "crengine"
    end
    return false
end

--- Quick AI Book Tools posture picker with a For-this-book ↔ Global target toggle
-- (tools_ux_plan.md §3) — mirrors the Domain & Research picker. Shared entry point for
-- the Quick Settings chip; the Book Settings screen has its own per-book-only row.
-- Book target: Follow global / On / Off (KEY_TOOLS sidecar key; legacy posture
-- strings read as their binary equivalent). Global target: On / Off
-- (features.enable_book_tools — the 2026-08-12 binary collapse).
-- @param opts table: { plugin, ui, document_path, on_close, target_override }
--- Tri-state Automatic X-Ray picker (§7 P1) — shared by the Book Settings row
--- and both X-Ray popup rows. Defined AFTER resolveDocSettings (file-local
--- upvalue scope). opts = { plugin, ui, document_path, on_change (called after
--- a pick; refresh state + reopen your surface), on_cancel }.
function BookSettings.showXrayAutoPicker(opts)
    opts = opts or {}
    local doc_settings = resolveDocSettings(opts.ui, opts.document_path)
    if not doc_settings then return end
    local features = opts.plugin and opts.plugin.settings
        and opts.plugin.settings:readSetting("features") or {}
    local cur = BookSettings.xrayAutoOverride(doc_settings, features)
    local global_on = features.xray_auto_update == true
    local function dot(on) return on and "● " or "○ " end
    local picker
    local function pick(val)
        doc_settings:saveSetting(BookSettings.KEY_XRAY_AUTO, val)
        doc_settings:flush()
        UIManager:close(picker)
        if opts.on_change then opts.on_change() end
        -- Round 19 (after on_change so the catch-up dialog lands ON TOP of a
        -- re-opened popup): picking On on a book with no X-Ray yet gets the
        -- same honest catch-up flow as the Create form's follow pick
        if val == "on" and opts.plugin and opts.plugin._onXrayAutoTurnedOn then
            opts.plugin:_onXrayAutoTurnedOn()
        end
    end
    picker = ButtonDialog:new{
        title = _("Automatic X-Ray (this book)") .. "\n"
            .. _("On: build this book's X-Ray automatically as you read: a spoiler-free introduction first, then checkpoints, always keeping the next one ready ahead of you (background API calls; WiFi + text-extraction consent required).")
            .. (isPageBased(opts.ui, opts.document_path)
                and ("\n" .. _("This book is page-based (PDF/DJVU): automatic X-Ray only runs on flowing books (EPUB), so this setting has no effect here."))
                or ""),
        buttons = {
            {{ text = dot(cur == nil) .. T(_("Follow global (%1)"), global_on and _("On") or _("Off")),
                callback = function() pick(nil) end }},
            {{ text = dot(cur == "on") .. _("On: fully automatic"),
                callback = function() pick("on") end }},
            {{ text = dot(cur == "off") .. _("Off: never automatic"),
                callback = function() pick("off") end }},
            {{ text = _("Cancel"), id = "close",
                callback = function()
                    UIManager:close(picker)
                    if opts.on_cancel then opts.on_cancel() end
                end }},
        },
        tap_close_callback = function() if opts.on_cancel then opts.on_cancel() end end,
    }
    UIManager:show(picker)
end

--- Canonical two-layer picker engine (book_global_consolidation_plan.md P1,
-- 2026-08-16). ONE implementation of the For-this-book ↔ Global picker shape
-- every book-overridable setting shares (the showWebSearch shape): target
-- toggle header row with dot marks, book tab led by the explicit
-- "Follow global (<current value>)" reset row, then one radio row per value —
-- binaries and value ladders alike. The showX entry points below are thin
-- spec wrappers; a NEW two-layer picker adds a spec, never a clone.
-- spec fields:
--   title        string, or fn(ctx) -> string (dynamic note lines, e.g. spoiler)
--   key          sidecar key (book layer; picking nil = follow global)
--   options      { { value=..., label=... }, ... } radio rows, in order
--   global       fn(features) -> current global value (the check pattern lives
--                there so it always matches the schema default)
--   field        features key for the plain global write, OR:
--   set_global   fn(features_tbl, val) custom global write (mutate only;
--                the engine saves + flushes)
--   read_book    optional fn(doc_settings) -> value (legacy normalization)
--   value_label  optional fn(value) -> short label for the Follow-global row
--                (default: the matching option's label)
--   top_rows     optional fn(ctx) -> button rows ABOVE the target toggle
--   bottom_rows  optional fn(ctx) -> button rows between values and Close
--   option_extra optional fn(ctx, value, selected) -> button|nil appended to
--                that option's row (inline dials, e.g. the context amount)
--   on_commit    optional fn(plugin) extra hook after any write
-- ctx handed to title/top_rows/bottom_rows: { doc_settings, features,
-- is_book_target, plugin, ui, document_path, on_close, closeDialog }.
-- opts (every wrapper's public contract, unchanged):
-- { plugin, ui, document_path, on_close, target_override }
function BookSettings.showLayeredPicker(spec, opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close
    local document_path = opts.document_path

    local doc_settings = resolveDocSettings(ui, document_path)
    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}
    -- Explicit if-chain: read_book may legitimately return false (an and/or
    -- fold here would drop explicit-off overrides)
    local book_val = nil
    if doc_settings then
        if spec.read_book then
            book_val = spec.read_book(doc_settings)
        else
            book_val = doc_settings:readSetting(spec.key)
        end
    end
    local global_val = spec.global(features)

    -- Default to "book" only when the book already has an override, else "global".
    local target = opts.target_override
        or (doc_settings and book_val ~= nil and "book")
        or "global"
    local is_book_target = doc_settings ~= nil and target == "book"

    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function commit()
        closeDialog()
        if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
        if spec.on_commit then spec.on_commit(plugin) end
        if on_close then on_close() end
    end
    local function pickBook(val)
        require("koassistant_logger").dbg("KOAssistant BookSettings: book override",
            spec.key, "=", tostring(val))
        doc_settings:saveSetting(spec.key, val)
        doc_settings:flush()
        commit()
    end
    local function pickGlobal(val)
        require("koassistant_logger").dbg("KOAssistant BookSettings: global",
            spec.field or spec.key, "=", tostring(val))
        local f = plugin.settings:readSetting("features") or {}
        if spec.set_global then
            spec.set_global(f, val)
        else
            f[spec.field] = val
        end
        plugin.settings:saveSetting("features", f)
        plugin.settings:flush()
        commit()
    end
    local function setTarget(new_target)
        closeDialog()
        local reopen = {}
        for k, v in pairs(opts) do reopen[k] = v end
        reopen.target_override = new_target
        BookSettings.showLayeredPicker(spec, reopen)
    end
    local function dot(active) return active and "● " or "○ " end
    local function valueLabel(v)
        if spec.value_label then return spec.value_label(v) end
        for _idx, o in ipairs(spec.options) do
            if o.value == v then return o.label end
        end
        return tostring(v)
    end

    local ctx = {
        doc_settings = doc_settings, features = features,
        is_book_target = is_book_target, plugin = plugin, ui = ui,
        document_path = document_path, on_close = on_close,
        closeDialog = closeDialog,
    }

    local buttons = {}
    if spec.top_rows then
        for _idx, row in ipairs(spec.top_rows(ctx)) do table.insert(buttons, row) end
    end
    -- Target toggle row: [For this book] [Global] — only when a book is in scope
    if doc_settings then
        table.insert(buttons, {
            {
                text = dot(is_book_target) .. _("For this book"),
                callback = function()
                    if not is_book_target then setTarget("book") end
                end,
            },
            {
                text = dot(not is_book_target) .. _("Global"),
                callback = function()
                    if is_book_target then setTarget("global") end
                end,
            },
        })
    end

    -- Optional per-option companion button (spec.option_extra(ctx, value,
    -- selected) -> button|nil), appended to that option's row — the inline
    -- amount dial's seat (round 6, maintainer design: the number sits next to
    -- the picked mode, not on its own row)
    local function optionRow(o, selected, pick_fn)
        local row = { {
            text = dot(selected) .. o.label,
            callback = function() pick_fn(o.value) end,
        } }
        if spec.option_extra then
            local extra = spec.option_extra(ctx, o.value, selected)
            if extra then row[#row + 1] = extra end
        end
        return row
    end
    if is_book_target then
        table.insert(buttons, {{
            text = dot(book_val == nil) .. T(_("Follow global (%1)"), valueLabel(global_val)),
            callback = function() pickBook(nil) end,
        }})
        for _idx, o in ipairs(spec.options) do
            table.insert(buttons, optionRow(o, book_val == o.value, pickBook))
        end
    else
        for _idx, o in ipairs(spec.options) do
            table.insert(buttons, optionRow(o, global_val == o.value, pickGlobal))
        end
    end
    if spec.bottom_rows then
        for _idx, row in ipairs(spec.bottom_rows(ctx)) do table.insert(buttons, row) end
    end
    table.insert(buttons, {{
        text = _("Close"), id = "close",
        callback = function()
            closeDialog()
            if on_close then on_close() end
        end,
    }})

    local title = spec.title
    if type(title) == "function" then title = title(ctx) end
    dialog = ButtonDialog:new{ title = title, buttons = buttons,
        tap_close_callback = function() dialog = nil; if on_close then on_close() end end }
    UIManager:show(dialog)
end

--- Label grammar for rows/tiles that DISPLAY a two-layer value (the P4 sweep
-- consumer): "<Setting>: <value> (book|global)". The layer tag mirrors
-- override PRESENCE (Q3: same-as-global picks are real pins); a row following
-- global still names the value — bare "(global)" with no value is the C1
-- defect this round retires.
function BookSettings.layeredLabel(setting_label, value_label, layer)
    if layer == "book" then
        return T(_("%1: %2 (book)"), setting_label, value_label)
    elseif layer == "global" then
        return T(_("%1: %2 (global)"), setting_label, value_label)
    end
    return T(_("%1: %2"), setting_label, value_label)
end

--- Quick AI-Book-Tools picker (For this book ↔ Global) — the Tools chip's hold
-- target and the QS tile hold. Book: Follow global / On / Off (KEY_TOOLS).
-- Global: On / Off (features.enable_book_tools; legacy tools_posture cleared).
-- @param opts table: { plugin, ui, document_path, on_close, target_override }
function BookSettings.showToolsPosture(opts)
    BookSettings.showLayeredPicker({
        title = _("AI Book Tools"),
        key = BookSettings.KEY_TOOLS,
        -- Legacy per-book strings ("auto"/"manual"/"off") read as their binary
        -- equivalent; new writes store true/false/nil only
        read_book = function(ds) return toolsValueOn(ds:readSetting(BookSettings.KEY_TOOLS)) end,
        global = function(f) return BookSettings.resolveBookTools(nil, f) end,
        set_global = function(f, val)
            f.enable_book_tools = val
            f.tools_posture = nil
        end,
        options = {
            { value = true, label = _("On") },
            { value = false, label = _("Off") },
        },
        value_label = function(v) return v and _("On") or _("Off") end,
        bottom_rows = function(ctx)
            -- Lookup effort row → effort sub-picker (inherits the current
            -- book/global target).
            local book_effort = ctx.doc_settings
                and ctx.doc_settings:readSetting(BookSettings.KEY_TOOL_EFFORT) or nil
            local global_effort = ctx.features.tool_lookup_effort or "standard"
            local eff_label = ctx.is_book_target
                and (book_effort and BookSettings.toolEffortLabel(book_effort)
                     or T(_("Follow global (%1)"), BookSettings.toolEffortLabel(global_effort)))
                or BookSettings.toolEffortLabel(global_effort)
            return {{{
                text = T(_("Lookup effort: %1"), eff_label),
                callback = function()
                    ctx.closeDialog()
                    BookSettings.showEffortPicker({
                        plugin = ctx.plugin, ui = ctx.ui, document_path = ctx.document_path,
                        on_close = ctx.on_close, kind = "tool",
                        target_override = ctx.is_book_target and "book" or "global",
                    })
                end,
            }}}
        end,
    }, opts)
end

--- Quick web-search picker (For this book ↔ Global) — the QS chip and the Web
-- chip's hold target. Book: Follow global / On / Off (KEY_WEB_SEARCH sidecar
-- key). Global: On / Off (features.enable_web_search).
-- @param opts table: { plugin, ui, document_path, on_close, target_override }
function BookSettings.showWebSearch(opts)
    BookSettings.showLayeredPicker({
        title = _("Web Search"),
        key = BookSettings.KEY_WEB_SEARCH,
        field = "enable_web_search",
        global = function(f) return f.enable_web_search == true end,
        options = {
            { value = true, label = _("On") },
            { value = false, label = _("Off") },
        },
        bottom_rows = function(ctx)
            -- Search depth row → effort sub-picker (inherits the current
            -- book/global target).
            local book_depth = ctx.doc_settings
                and ctx.doc_settings:readSetting(BookSettings.KEY_WEB_EFFORT) or nil
            local global_depth = ctx.features.web_search_effort or "standard"
            local depth_label = ctx.is_book_target
                and (book_depth and BookSettings.webEffortLabel(book_depth)
                     or T(_("Follow global (%1)"), BookSettings.webEffortLabel(global_depth)))
                or BookSettings.webEffortLabel(global_depth)
            return {{{
                text = T(_("Search depth: %1"), depth_label),
                callback = function()
                    ctx.closeDialog()
                    BookSettings.showEffortPicker({
                        plugin = ctx.plugin, ui = ctx.ui, document_path = ctx.document_path,
                        on_close = ctx.on_close, kind = "web",
                        target_override = ctx.is_book_target and "book" or "global",
                    })
                end,
            }}}
        end,
    }, opts)
end

--- Per-book effort sub-picker (Tools lookup effort / Web search depth) reached
-- from the effort rows above; one wrapper serves both via opts.kind. The
-- engine's target re-shows keep kind through the shared spec.
-- @param opts table: { plugin, ui, document_path, on_close, target_override, kind="tool"|"web" }
function BookSettings.showEffortPicker(opts)
    opts = opts or {}
    local spec
    if opts.kind == "web" then
        spec = {
            title = _("Web Search Depth"),
            key = BookSettings.KEY_WEB_EFFORT,
            field = "web_search_effort",
            global = function(f) return f.web_search_effort or "standard" end,
            value_label = BookSettings.webEffortLabel,
            options = {
                { value = "light", label = _("Light (fewest searches)") },
                { value = "standard", label = _("Standard") },
                { value = "thorough", label = _("Thorough (most searches)") },
            },
        }
    else
        spec = {
            title = _("Book Tools Lookup Effort"),
            key = BookSettings.KEY_TOOL_EFFORT,
            field = "tool_lookup_effort",
            global = function(f) return f.tool_lookup_effort or "standard" end,
            value_label = BookSettings.toolEffortLabel,
            options = {
                { value = "quick", label = _("Quick (up to 4 lookups)") },
                { value = "standard", label = _("Standard (up to 8 lookups)") },
                { value = "thorough", label = _("Thorough (up to 16 lookups)") },
            },
        }
    end
    BookSettings.showLayeredPicker(spec, opts)
end

--- Quick Answer DEFAULT picker (For this book ↔ Global) — governs the ⚡ chip's
-- starting state on fresh chat dialogs only; open chats and the session chip
-- are untouched. Book: Follow global / On / Off (KEY_QUICK_ANSWER). Global:
-- On / Off (features.quick_answer_default). opts.preset_settings (fn(on_close))
-- adds the "Preset settings…" top row (⚡ hold surfaces).
-- @param opts table: { plugin, ui, document_path, on_close, target_override, preset_settings }
function BookSettings.showQuickAnswerDefault(opts)
    opts = opts or {}
    local preset_settings = opts.preset_settings
    BookSettings.showLayeredPicker({
        title = _("Quick Answer Default"),
        key = BookSettings.KEY_QUICK_ANSWER,
        field = "quick_answer_default",
        global = function(f) return f.quick_answer_default == true end,
        options = {
            { value = true, label = _("On") },
            { value = false, label = _("Off") },
        },
        top_rows = function(ctx)
            if not preset_settings then return {} end
            -- ⚡ chip / reply-window hold (2026-08-11): the preset editor rides
            -- on top of the default picker — one popup, Web/Tools-chip shape.
            return {{{
                text = _("Preset settings…"),
                callback = function()
                    ctx.closeDialog()
                    -- Hand the picker's on_close down the chain so the editor's
                    -- Close/dismiss still returns to the launching surface (the
                    -- QS panel got lost here otherwise)
                    preset_settings(ctx.on_close)
                end,
            }}}
        end,
    }, opts)
end

--- Quick spoiler-protection picker (For this book ↔ Global) — the Spoiler
-- chip's hold target and the QS tile hold. Book: Follow global / On / Off
-- (KEY_SPOILER_FREE). Global: On / Off (features.spoiler_free_chat, default ON).
-- @param opts table: { plugin, ui, document_path, on_close, target_override }
function BookSettings.showSpoilerFree(opts)
    BookSettings.showLayeredPicker({
        -- §5 research labelling, never graying: research mode (and, since
        -- 2026-08-11, the Finished status) disables protection outright — say
        -- so while still showing the stored state the rows edit.
        title = function(ctx)
            local title = _("Spoiler Protection")
            local summary = ctx.doc_settings and ctx.doc_settings:readSetting("summary")
            if BookSettings.resolveResearch(ctx.doc_settings, ctx.features) then
                title = title .. "\n" .. _("Research mode is on: protection is disabled while it stays on.")
            elseif summary and summary.status == "complete" then
                title = title .. "\n" .. _("This book is marked finished: protection is off while it stays finished.")
            end
            return title
        end,
        key = BookSettings.KEY_SPOILER_FREE,
        field = "spoiler_free_chat",
        global = function(f) return f.spoiler_free_chat ~= false end,
        options = {
            { value = true, label = _("On") },
            { value = false, label = _("Off") },
        },
        on_commit = function(plugin)
            -- 50(f): spoiler posture may have flipped — let X-Ray promotion
            -- re-evaluate now instead of waiting for a page turn (safe no-op
            -- when nothing applies; rung-completion granularity while a chain
            -- runs)
            if plugin and plugin._scheduleXrayLadderPromotion then
                plugin:_scheduleXrayLadderPromotion()
            end
        end,
    }, opts)
end

--- Scope-aware highlight-context mode picker (For this book / Global) — the Ctx
-- chip's hold target (flexible_scope_plan.md phase 3 finishing round). Sets the
-- PERSISTENT defaults; the chip's tap sets the session override. Book: Follow
-- global / modes (KEY_HIGHLIGHT_CONTEXT). Global: features.highlight_context_mode.
-- @param opts table: { plugin, ui, document_path, on_close, target_override }
-- P5 (granularity round 2, maintainer): the spoiler clamp's user-facing pieces,
-- shared by BOTH context pickers. Note = the title line while protection is on
-- (says exactly what the configured limit does; nil when the limit is "off").
local function spoilerContextNote(features)
    local lim = features.spoiler_context_limit or "paragraph"
    if lim == "off" then return nil end
    if lim == "selection" then
        return _("Spoiler protection is on: context is taken only from before the selection.")
    elseif lim == "sentence" then
        return _("Spoiler protection is on: context after the selection stops at the end of its sentence.")
    end
    return _("Spoiler protection is on: context after the selection stops at the end of its paragraph.")
end
-- Global feature write + live push, shared by the pickers' global dial rows
local function writeGlobalFeature(plugin, k, v)
    if plugin and plugin.settings then
        local f = plugin.settings:readSetting("features") or {}
        f[k] = v
        plugin.settings:saveSetting("features", f)
        plugin.settings:flush()
        if plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
    end
end

--- Short label for a spoiler-clamp VALUE — exported for the Ctx chip's tap
-- popup, where the clamp is a per-request dial (round 7; replaced the
-- round-6 title-note export there).
function BookSettings.spoilerLimitLabel(lim)
    lim = lim or "paragraph"
    if lim == "off" then return _("No limit") end
    if lim == "selection" then return _("Nothing after") end
    if lim == "sentence" then return _("To sentence end") end
    return _("To paragraph end")
end
local function spoilerContextLimitLabel(features)
    return BookSettings.spoilerLimitLabel(features.spoiler_context_limit)
end

-- The GLOBAL context dials both pickers carry as bottom rows: direction
-- (both sides / before only) and the spoiler clamp granularity (tap-cycles
-- selection → sentence → paragraph → off). The AMOUNT moved off its own row
-- in round 6 — it rides the picked mode row as an inline companion button
-- (spec.option_extra; the highlight picker only, maintainer: the dictionary
-- picker stays as it is). show_fn = the calling picker, so a tap re-shows it
-- with fresh labels on the same tab.
local function contextGlobalRows(ctx, show_fn)
    local function reopen()
        show_fn({
            plugin = ctx.plugin, ui = ctx.ui, document_path = ctx.document_path,
            on_close = ctx.on_close,
            target_override = ctx.is_book_target and "book" or "global",
        })
    end
    local before_only = ctx.features.highlight_context_direction == "before"
    return {
        {{
            text = T(_("Direction: %1 (global)"),
                before_only and _("Before only") or _("Both sides")),
            callback = function()
                writeGlobalFeature(ctx.plugin, "highlight_context_direction",
                    (not before_only) and "before" or nil)
                ctx.closeDialog()
                reopen()
            end,
        }},
        {{
            text = T(_("Under spoiler protection: %1 (global)"),
                spoilerContextLimitLabel(ctx.features)),
            callback = function()
                local cur = ctx.features.spoiler_context_limit or "paragraph"
                local next_v = ({ selection = "sentence", sentence = "paragraph",
                    paragraph = "off", off = "selection" })[cur] or "paragraph"
                writeGlobalFeature(ctx.plugin, "spoiler_context_limit", next_v)
                ctx.closeDialog()
                reopen()
            end,
        }},
    }
end

-- The inline amount companion for a context-mode picker row (round 6): the
-- number next to the picked mode, tap cycles. GLOBAL amounts — the only
-- amount keys that exist; the per-request override lives on the Ctx chip's
-- tap popup. paragraph 1→5, characters 100/250/500/1000.
local function contextAmountExtra(ctx, show_fn, value, selected)
    if not selected then return nil end
    local key, next_map, cur
    if value == "paragraph" then
        key = "highlight_context_paragraphs"
        cur = tonumber(ctx.features[key]) or 1
    elseif value == "characters" then
        key = "highlight_context_chars"
        cur = tonumber(ctx.features[key]) or 100
        next_map = { [100] = 250, [250] = 500, [500] = 1000, [1000] = 100 }
    else
        return nil
    end
    return {
        text = tostring(cur),
        callback = function()
            local next_v
            if next_map then next_v = next_map[cur] or 100
            else next_v = cur >= 5 and 1 or cur + 1 end
            writeGlobalFeature(ctx.plugin, key, next_v)
            ctx.closeDialog()
            show_fn({
                plugin = ctx.plugin, ui = ctx.ui, document_path = ctx.document_path,
                on_close = ctx.on_close,
                target_override = ctx.is_book_target and "book" or "global",
            })
        end,
    }
end

function BookSettings.showHighlightContext(opts)
    local options = {}
    for _idx, m in ipairs({ "none", "sentence", "paragraph", "characters" }) do
        table.insert(options, { value = m, label = BookSettings.contextModeLabel(m) })
    end
    BookSettings.showLayeredPicker({
        -- P5: the spoiler clamp is invisible mechanics — say what it does where
        -- the mode is picked (label, never gray: the stored pick stays editable).
        title = function(ctx)
            local title = _("Context Around Highlights")
            local note = BookSettings.resolveSpoilerFree(ctx.doc_settings, ctx.features)
                and spoilerContextNote(ctx.features) or nil
            if note then title = title .. "\n" .. note end
            return title
        end,
        key = BookSettings.KEY_HIGHLIGHT_CONTEXT,
        field = "highlight_context_mode",
        global = function(f) return f.highlight_context_mode or "none" end,
        value_label = BookSettings.contextModeLabel,
        options = options,
        option_extra = function(ctx, value, selected)
            return contextAmountExtra(ctx, BookSettings.showHighlightContext, value, selected)
        end,
        bottom_rows = function(ctx)
            return contextGlobalRows(ctx, BookSettings.showHighlightContext)
        end,
    }, opts)
end

--- Scope-aware dictionary-context mode picker (For this book / Global) — the
-- Chat behavior row's target (consolidation P2, 2026-08-16; was a book-only
-- local picker with no global reach). Sets the PERSISTENT defaults for the
-- dictionary {context_section} channel; the dictionary popup's Ctx button
-- stays the per-lookup toggle. Book: Follow global / modes
-- (KEY_DICTIONARY_CONTEXT). Global: features.dictionary_context_mode
-- (default "sentence" — the resolver owns it, see resolveDictionaryContext).
-- @param opts table: { plugin, ui, document_path, on_close, target_override }
function BookSettings.showDictionaryContext(opts)
    local options = {}
    for _idx, m in ipairs({ "none", "sentence", "paragraph", "characters" }) do
        table.insert(options, { value = m, label = BookSettings.contextModeLabel(m) })
    end
    BookSettings.showLayeredPicker({
        -- P5: the spoiler clamp covers the dictionary channel too — same note
        -- and the same two global dials.
        title = function(ctx)
            local title = _("Context Around Dictionary Lookups")
            local note = BookSettings.resolveSpoilerFree(ctx.doc_settings, ctx.features)
                and spoilerContextNote(ctx.features) or nil
            if note then title = title .. "\n" .. note end
            return title
        end,
        -- No option_extra: the dictionary picker keeps its shape (round 6,
        -- maintainer: "this we dont want to mess with")
        bottom_rows = function(ctx)
            return contextGlobalRows(ctx, BookSettings.showDictionaryContext)
        end,
        key = BookSettings.KEY_DICTIONARY_CONTEXT,
        field = "dictionary_context_mode",
        global = function(f) return f.dictionary_context_mode or "sentence" end,
        value_label = BookSettings.contextModeLabel,
        options = options,
    }, opts)
end

--- Short labels for the X-Ray marking values — shared by the Marking & lookup
-- popup rows and the pickers below (P3's X-Ray sub-screen reuses both).
function BookSettings.xrayMarkingDensityLabel(v)
    if v == "all" then return _("All occurrences")
    elseif v == "first" then return _("Once per page")
    elseif v == "10" then return _("After 10 unseen pages")
    elseif v == "25" then return _("After 25 unseen pages")
    elseif v == "once" then return _("First appearance only") end
    return tostring(v)
end

function BookSettings.xrayMarkingFamiliesLabel(v)
    if v == "people" then return _("People only")
    elseif v == "people_places" then return _("People & places")
    elseif v == "all" then return _("All entities") end
    return tostring(v)
end

function BookSettings.xrayCardModeLabel(v)
    if v == "popup" then return _("Floating popup")
    elseif v == "full" then return _("Full entry") end
    return _("Footnote panel")
end

function BookSettings.xrayCardLengthLabel(v)
    if v == "full" then return _("Full entry") end
    return _("First sentence")
end

function BookSettings.xrayAheadCardLabel(v)
    if v == "entry" then return _("First sentence") end
    return _("Name only, tap to show")
end

-- Category groups for the X-Ray category picker (presets v0.21). Ids and
-- per-type key mapping live in prompts/actions.lua (XRAY_CATEGORY_ORDER);
-- the user-facing labels live here with the picker.
local XRAY_CATEGORY_LABELS = {
    people = _("People & characters"),
    places = _("Places"),
    ideas = _("Themes & ideas"),
    terms = _("Terms & vocabulary"),
    events = _("Timeline & development"),
}

--- Effective category selection for NEW X-Rays: book pick > global default >
--- full. Sidecar value "full" is the explicit-full sentinel (this book stays
--- Full even under a narrowed global — the domain `_none` precedent); any
--- other sidecar value is a csv of group ids; nil follows the global
--- (`features.xray_default_categories`, csv, nil = full).
--- @param doc_settings table|nil the book's DocSettings (nil = no book layer)
--- @param features table|nil global features table
--- @return string|nil normalized csv (nil = full), string|nil deciding layer ("book"/"global")
function BookSettings.resolveXrayCategories(doc_settings, features)
    local Actions = require("prompts.actions")
    local raw = doc_settings and doc_settings:readSetting(BookSettings.KEY_XRAY_CATEGORIES)
    if raw == "full" then return nil, "book" end
    local sel = Actions.normalizeXrayCategories(raw)
    if sel then return sel, "book" end
    local gsel = Actions.normalizeXrayCategories(features and features.xray_default_categories)
    if gsel then return gsel, "global" end
    return nil, nil
end

--- Short label for a stored category selection (row/button text).
--- @param value string|nil raw stored value (normalized internally)
--- @return string "Full" / "Character tracking" / "N of 5"
function BookSettings.xrayCategoriesLabel(value)
    local Actions = require("prompts.actions")
    local sel = Actions.normalizeXrayCategories(value)
    if not sel then return _("Full") end
    if sel == "people" then return _("Character tracking") end
    if sel == "people,events" then return _("Light") end
    local n = 0
    for _id in sel:gmatch("[^,]+") do n = n + 1 end
    return T(_("%1 of %2"), n, #Actions.XRAY_CATEGORY_ORDER)
end

--- implicitly. Book mode (default) writes KEY_XRAY_CATEGORIES on the spot
--- (sticky, per-book): the "Follow global" row deletes the key, and explicit
--- Full writes the "full" sentinel so the book resists a narrowed global (the
--- domain `_none` precedent). Global mode (opts.target = "global", needs
--- opts.plugin for the write) edits features.xray_default_categories — the
--- default every book without its own pick follows. Callers get on_close to
--- refresh their surface. At least one group must stay checked (an X-Ray with
--- zero entity categories is rejected by the create gate). Self-rebuilding
--- dialog (marking-popup precedent); preset dots reflect the STORED pick of
--- the edited layer, checkboxes show the EFFECTIVE working set.
--- @param opts table { ui, document_path, on_close, target, plugin }
function BookSettings.showXrayCategoriesPicker(opts)
    opts = opts or {}
    local Actions = require("prompts.actions")
    local is_global = opts.target == "global"
    local features = opts.plugin and opts.plugin.settings
        and opts.plugin.settings:readSetting("features") or {}
    local doc_settings
    if not is_global then
        doc_settings = resolveDocSettings(opts.ui, opts.document_path)
        if not doc_settings then
            if opts.on_close then opts.on_close() end
            return
        end
    end
    -- Explicit branch, never `is_global and X or Y`: with no global set,
    -- X is nil and the fold would index the never-resolved doc_settings.
    local raw
    if is_global then
        raw = features.xray_default_categories
    else
        raw = doc_settings:readSetting(BookSettings.KEY_XRAY_CATEGORIES)
    end
    local stored = raw ~= "full" and Actions.normalizeXrayCategories(raw) or nil
    -- Working checkbox set seeds from the EFFECTIVE selection (book mode
    -- follows the global while unset) so a toggle starts from what a build
    -- would actually use.
    local sel
    if is_global then
        sel = stored
    else
        sel = BookSettings.resolveXrayCategories(doc_settings, features)
    end
    local set = {}
    if sel then
        for id in sel:gmatch("[^,]+") do set[id] = true end
    else
        for _idx, id in ipairs(Actions.XRAY_CATEGORY_ORDER) do set[id] = true end
    end

    local dialog
    local function save()
        local ids = {}
        for _idx, id in ipairs(Actions.XRAY_CATEGORY_ORDER) do
            if set[id] then ids[#ids + 1] = id end
        end
        local value = Actions.normalizeXrayCategories(table.concat(ids, ","))
        if is_global then
            writeGlobalFeature(opts.plugin, "xray_default_categories", value)
        elseif value then
            doc_settings:saveSetting(BookSettings.KEY_XRAY_CATEGORIES, value)
            doc_settings:flush()
        else
            -- All five checked in book mode = the explicit-full sentinel, not
            -- a key delete: checking every box is a deliberate pick and must
            -- survive a narrowed global. "Follow global" is the way back.
            doc_settings:saveSetting(BookSettings.KEY_XRAY_CATEGORIES, "full")
            doc_settings:flush()
        end
    end
    local function reshow()
        if dialog then UIManager:close(dialog); dialog = nil end
        BookSettings.showXrayCategoriesPicker(opts)
    end
    local function closeAll()
        if dialog then UIManager:close(dialog); dialog = nil end
        if opts.on_close then opts.on_close() end
    end
    local function countChecked()
        local n = 0
        for _id, on in pairs(set) do if on then n = n + 1 end end
        return n
    end
    local function dot(active) return active and "● " or "○ " end
    -- Toggle idiom shared with the quick-preset pickers (dialogs): ✓ / ○
    local function mark(active) return active and "✓ " or "○ " end

    local full_stored
    if is_global then full_stored = (stored == nil) else full_stored = (raw == "full") end
    local buttons = {}
    if not is_global then
        buttons[#buttons + 1] = {{ text = dot(raw == nil)
                .. T(_("Follow global (%1)"),
                    BookSettings.xrayCategoriesLabel(features.xray_default_categories)),
            callback = function()
                doc_settings:delSetting(BookSettings.KEY_XRAY_CATEGORIES)
                doc_settings:flush()
                reshow()
            end }}
    end
    buttons[#buttons + 1] = {{ text = dot(full_stored) .. _("Full (all categories)"),
        callback = function()
            for _idx, id in ipairs(Actions.XRAY_CATEGORY_ORDER) do set[id] = true end
            save()
            reshow()
        end }}
    -- Light (maintainer 2026-08-18): who + what happened. people + events =
    -- cast/key figures and story arc/argument development (the current-state
    -- singleton always rides regardless of selection). Deliberately NOT
    -- including places or ideas: ideas is the depth sink with the largest
    -- model variance, and a reader who wants either is one checkbox away.
    -- Presets stay meaningfully distinct at 1 / 2 / 5 groups.
    buttons[#buttons + 1] = {{ text = dot(stored == "people,events")
            .. _("Light (characters and story arc)"),
        callback = function()
            for _idx, id in ipairs(Actions.XRAY_CATEGORY_ORDER) do set[id] = nil end
            set.people = true
            set.events = true
            save()
            reshow()
        end }}
    buttons[#buttons + 1] = {{ text = dot(stored == "people")
            .. _("Character tracking (people only)"),
        callback = function()
            for _idx, id in ipairs(Actions.XRAY_CATEGORY_ORDER) do set[id] = nil end
            set.people = true
            save()
            reshow()
        end }}
    for _idx, id in ipairs(Actions.XRAY_CATEGORY_ORDER) do
        buttons[#buttons + 1] = {{ text = mark(set[id]) .. XRAY_CATEGORY_LABELS[id],
            callback = function()
                if set[id] and countChecked() == 1 then
                    UIManager:show(require("ui/widget/notification"):new{
                        text = _("At least one category must stay selected."),
                    })
                    return
                end
                set[id] = not set[id] or nil
                save()
                reshow()
            end }}
    end
    buttons[#buttons + 1] = {{ text = _("Done"), id = "close", callback = closeAll }}

    -- Kept SHORT (maintainer 2026-08-18): the explanatory paragraph pushed the
    -- category rows off the screen, so the picker had to be scrolled to reach
    -- the thing it exists for.
    local title = (is_global and _("Categories for new X-Rays (global)")
            or _("Categories for new X-Rays (this book)")) .. "\n"
        .. _("Applies to new builds and rebuilds. Fewer categories are faster and cheaper.")
    dialog = ButtonDialog:new{
        title = title,
        buttons = buttons,
        tap_close_callback = function()
            dialog = nil
            if opts.on_close then opts.on_close() end
        end,
    }
    UIManager:show(dialog)
end

--- Scope-aware X-Ray marking & lookup pickers (For this book / Global) —
-- consolidation P2 flagship (2026-08-16): the Marking & lookup popup's
-- tap-cycles became these canonical pickers. One wrapper serves the seven
-- keys via opts.kind: "enabled" | "density" | "families" | "tap" | "ahead" |
-- "intercept" | "card" | "card_length" | "ahead_card" (B269). Defaults mirror resolveXrayMarking (marking ON, tap
-- ON, density "10", families "all", ahead ON, intercept ON, card "footnote").
-- @param opts table: { plugin, ui, document_path, on_close, target_override, kind }
function BookSettings.showXrayMarkingPicker(opts)
    opts = opts or {}
    -- Any write re-syncs the ambient marks so the change shows this page
    local function commit(plugin)
        if plugin and plugin.syncXrayMarks then plugin:syncXrayMarks() end
    end
    local on_off = {
        { value = true, label = _("On") },
        { value = false, label = _("Off") },
    }
    local spec
    if opts.kind == "density" then
        local options = {}
        for _idx, v in ipairs({ "all", "first", "10", "25", "once" }) do
            table.insert(options, { value = v, label = BookSettings.xrayMarkingDensityLabel(v) })
        end
        spec = {
            title = _("Marking Density"),
            key = BookSettings.KEY_XRAY_MARKING_DENSITY,
            field = "xray_marking_density",
            global = function(f) return f.xray_marking_density or "10" end,
            value_label = BookSettings.xrayMarkingDensityLabel,
            options = options,
            on_commit = commit,
        }
    elseif opts.kind == "families" then
        local options = {}
        for _idx, v in ipairs({ "all", "people", "people_places" }) do
            table.insert(options, { value = v, label = BookSettings.xrayMarkingFamiliesLabel(v) })
        end
        spec = {
            title = _("Entities to Mark"),
            key = BookSettings.KEY_XRAY_MARKING_FAMILIES,
            field = "xray_marking_families",
            global = function(f) return f.xray_marking_families or "all" end,
            value_label = BookSettings.xrayMarkingFamiliesLabel,
            options = options,
            on_commit = commit,
        }
    elseif opts.kind == "tap" then
        spec = {
            title = _("Tap Marked Words"),
            key = BookSettings.KEY_XRAY_MARKING_TAP,
            field = "xray_marking_tap",
            global = function(f) return f.xray_marking_tap ~= false end,
            value_label = function(v) return v and _("On") or _("Off") end,
            options = on_off,
            on_commit = commit,
        }
    elseif opts.kind == "ahead" then
        -- Upcoming Entities (device round 3: same pattern as the other marking
        -- keys, not a global-only tap-cycle) — the ahead-checkpoint peek in
        -- marking, lookup and cards. The intercept/card sites read the resolver
        -- per call; commit re-syncs the marks index.
        spec = {
            title = _("Upcoming Entities"),
            key = BookSettings.KEY_XRAY_AHEAD,
            field = "xray_show_ahead_entities",
            global = function(f) return f.xray_show_ahead_entities ~= false end,
            value_label = function(v) return v and _("On") or _("Off") end,
            options = on_off,
            on_commit = commit,
        }
    elseif opts.kind == "intercept" then
        -- Matching selections open entries (round 5, per book): the gate is
        -- resolved per call at both intercept sites; commit re-gates the
        -- wrapper installs for the open book.
        spec = {
            title = _("Matching Selections Open Entries"),
            key = BookSettings.KEY_XRAY_INTERCEPT,
            field = "xray_selection_intercept",
            global = function(f) return f.xray_selection_intercept ~= false end,
            value_label = function(v) return v and _("On") or _("Off") end,
            options = on_off,
            on_commit = function(plugin)
                if plugin and plugin.syncDictionaryBypass then plugin:syncDictionaryBypass() end
                if plugin and plugin.syncHighlightBypass then plugin:syncHighlightBypass() end
            end,
        }
    elseif opts.kind == "card" then
        -- Exact hits open (round 5, per book): one three-way value; the global
        -- side is the landing+style PAIR, written together.
        spec = {
            title = _("Exact Hits Open"),
            key = BookSettings.KEY_XRAY_CARD,
            global = function(f)
                if f.xray_card_landing == false then return "full" end
                if f.xray_card_style == "popup" then return "popup" end
                return "footnote"
            end,
            set_global = function(f, v)
                if v == "full" then
                    f.xray_card_landing = false
                else
                    f.xray_card_landing = true
                    f.xray_card_style = v
                end
            end,
            value_label = BookSettings.xrayCardModeLabel,
            options = {
                { value = "footnote", label = _("Footnote panel") },
                { value = "popup", label = _("Floating popup") },
                { value = "full", label = _("Full entry") },
            },
        }
    elseif opts.kind == "card_length" then
        -- B269: what the card shows for entries at or behind the position
        spec = {
            title = _("Card Shows"),
            key = BookSettings.KEY_XRAY_CARD_LENGTH,
            field = "xray_card_length",
            global = function(f) return f.xray_card_length == "full" and "full" or "sentence" end,
            value_label = BookSettings.xrayCardLengthLabel,
            options = {
                { value = "sentence", label = _("First sentence") },
                { value = "full", label = _("Full entry") },
            },
        }
    elseif opts.kind == "ahead_card" then
        -- B269: the card for UPCOMING entities (the ahead peek); name-only by
        -- default so an alias-folded identity never reveals on sight
        spec = {
            title = _("Upcoming Entity Cards"),
            key = BookSettings.KEY_XRAY_AHEAD_CARD,
            field = "xray_ahead_card",
            global = function(f) return f.xray_ahead_card == "entry" and "entry" or "name" end,
            value_label = BookSettings.xrayAheadCardLabel,
            options = {
                { value = "name", label = _("Name only, tap to show") },
                { value = "entry", label = _("First sentence right away") },
            },
        }
    else -- "enabled"
        spec = {
            title = _("Passive Marking"),
            key = BookSettings.KEY_XRAY_MARKING,
            field = "xray_marking",
            global = function(f) return f.xray_marking ~= false end,
            value_label = function(v) return v and _("On") or _("Off") end,
            options = on_off,
            on_commit = commit,
        }
    end
    BookSettings.showLayeredPicker(spec, opts)
end

--- Per-book "Book Settings" — a dedicated per-book configuration screen. Every row is
-- about THIS book (no For-this-book/Global toggle); each setting offers "Follow global"
-- plus per-book overrides. Compact rows that open small sub-pickers, so the screen scales
-- as more per-book settings are added. For the Quick Actions panel, file browser, and the
-- input-dialog button. (Reader/file-browser only — a book must be in scope.)
-- @param opts table: { plugin, ui, document_path, on_close }
function BookSettings.show(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close

    local doc_settings = resolveDocSettings(ui, opts.document_path)
    if not doc_settings then return end  -- per-book screen; nothing to configure without a book

    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}

    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function reopen()
        closeDialog()
        BookSettings.show(opts)
    end
    local function syncConfig()
        if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
    end

    -- Seam 2 (2026-08-12) + consolidation P2 (2026-08-16): rows open the SHARED
    -- scope-aware pickers on the book tab (Global one tap away) instead of
    -- hand-rolled book-only locals — the same dialogs as the chip holds and QS
    -- tiles. Domain and Research share one dialog (showDomainResearch). The
    -- Chat behavior sub-screen keeps its own copy of this helper for the
    -- tools/web/quick/highlight-context rows.
    local function sharedPicker(show_fn)
        closeDialog()
        show_fn({
            plugin = plugin, ui = ui, document_path = opts.document_path,
            target_override = "book",
            on_close = function() BookSettings.show(opts) end,
        })
    end

    -- Current per-book values → row labels. Consolidation P4 (2026-08-16,
    -- maintainer ask): follow-global rows carry the effective global value —
    -- "Follow global (On)" — matching the pickers' reset rows.
    local function boolLabel(v, global_on)
        if v == true then return _("On")
        elseif v == false then return _("Off")
        else return T(_("Follow global (%1)"), global_on and _("On") or _("Off")) end
    end

    local book_domain = doc_settings:readSetting(BookSettings.KEY_DOMAIN)
    local domain_label
    if book_domain == "_none" then domain_label = _("None")
    elseif book_domain == nil then
        local g = features.selected_domain
        domain_label = T(_("Follow global (%1)"),
            g and (domainDisplayName(g, features) or g) or _("None"))
    else domain_label = domainDisplayName(book_domain, features) or book_domain end

    local research_label = boolLabel(doc_settings:readSetting(BookSettings.KEY_RESEARCH),
        features.research_mode == true)
    local spoiler_label = boolLabel(doc_settings:readSetting(BookSettings.KEY_SPOILER_FREE),
        features.spoiler_free_chat ~= false)

    -- Regrouped 2026-08-12 (release prep A7 — the flat screen ran 13 "AI behavior"
    -- rows; consolidation P3 2026-08-16 moved the X-Ray rows into their own
    -- sub-screen): headline rows carry the identity of the reading (domain, background,
    -- research, spoiler protection, X-Ray, group); the dial-shaped rows moved to
    -- the Chat behavior / Privacy / Identity sub-screens below. Setting buttons
    -- stay paired two per row (maintainer 2026-07-12 — the screen got long); an
    -- odd leftover before a group break or full-width row takes the whole row.
    local buttons = {}
    local pending  -- unpaired setting button waiting for a row partner
    local function flushPair()
        if pending then
            table.insert(buttons, { pending })
            pending = nil
        end
    end
    local function addButton(btn)
        if pending then
            table.insert(buttons, { pending, btn })
            pending = nil
        else
            pending = btn
        end
    end
    local function addFullRow(btn)
        flushPair()
        table.insert(buttons, { btn })
    end

    addButton({ text = T(_("Domain: %1"), domain_label),
        callback = function() sharedPicker(BookSettings.showDomainResearch) end })
    -- Background: the reader's standing note about this book (book_background_plan.md)
    addButton({ text = T(_("Background: %1"), BookSettings.backgroundRowLabel(doc_settings)),
        callback = function()
            closeDialog()
            BookSettings.showBackgroundEditor({
                plugin = plugin, doc_settings = doc_settings,
                on_close = function() BookSettings.show(opts) end,
            })
        end })
    addButton({ text = T(_("Research mode: %1"), research_label),
        callback = function() sharedPicker(BookSettings.showDomainResearch) end })
    -- §5 research labelling, never graying: when research mode or the
    -- Finished status disables protection the row says so but keeps showing
    -- (and editing) the stored state — graying would hide a value the user set.
    local research_active = doc_settings:readSetting(BookSettings.KEY_RESEARCH)
    if research_active == nil then research_active = features.research_mode == true end
    local book_summary = doc_settings:readSetting("summary")
    local finished_active = research_active ~= true
        and book_summary and book_summary.status == "complete" or false
    local spoiler_row
    if research_active == true then
        spoiler_row = T(_("Spoiler protection: %1 (off: research mode)"), spoiler_label)
    elseif finished_active then
        spoiler_row = T(_("Spoiler protection: %1 (off: book finished)"), spoiler_label)
    else
        spoiler_row = T(_("Spoiler protection: %1"), spoiler_label)
    end
    -- The spoiler picker carries the research/finished note lines itself.
    addButton({ text = spoiler_row,
        callback = function() sharedPicker(BookSettings.showSpoilerFree) end })
    -- (Automatic X-Ray + X-Ray updates moved to the X-Ray sub-screen —
    -- consolidation P3 / Q1b, 2026-08-16.)
    -- Book groups (item 46): membership lives in the groups store, not a
    -- sidecar key — never counts toward "(N customized)"
    local groups_file = opts.document_path or (ui and ui.document and ui.document.file)
    if groups_file then
        addButton({ text = T(_("Group: %1"),
                require("koassistant_book_groups_ui").rowLabel(groups_file)),
            callback = function()
                closeDialog()
                require("koassistant_book_groups_ui").showBookRow(groups_file, {
                    plugin = plugin, ui = ui,
                    on_close = function() BookSettings.show(opts) end,
                })
            end })
    end
    flushPair()

    -- Sub-screen rows, each with that group's customized count (same non-nil
    -- rule as the title's "(N customized)") so moved values stay findable from
    -- the top screen.
    local function groupCount(keys)
        local n = 0
        for _i, k in ipairs(keys) do
            if doc_settings:readSetting(k) ~= nil then n = n + 1 end
        end
        return n
    end
    local function subScreenRow(label, n, show_fn)
        return {
            text = (n > 0) and T(_("%1 (%2) ▸"), label, n) or T(_("%1 ▸"), label),
            callback = function()
                closeDialog()
                show_fn({
                    plugin = plugin, ui = ui, document_path = opts.document_path,
                    on_close = function() BookSettings.show(opts) end,
                })
            end,
        }
    end
    addButton(subScreenRow(_("X-Ray"), groupCount({
        BookSettings.KEY_XRAY_AUTO, BookSettings.KEY_XRAY_GOAL,
        BookSettings.KEY_XRAY_PROMOTION, BookSettings.KEY_XRAY_SPACING,
        BookSettings.KEY_XRAY_MARKING, BookSettings.KEY_XRAY_MARKING_DENSITY,
        BookSettings.KEY_XRAY_MARKING_FAMILIES, BookSettings.KEY_XRAY_MARKING_TAP,
        BookSettings.KEY_XRAY_AHEAD, BookSettings.KEY_XRAY_INTERCEPT,
        BookSettings.KEY_XRAY_CARD, BookSettings.KEY_XRAY_CARD_LENGTH,
        BookSettings.KEY_XRAY_AHEAD_CARD, BookSettings.KEY_XRAY_CATEGORIES,
    }), BookSettings.showXrayConfig))
    addButton(subScreenRow(_("Chat behavior"), groupCount({
        BookSettings.KEY_TOOLS, BookSettings.KEY_WEB_SEARCH,
        BookSettings.KEY_QUICK_ANSWER, BookSettings.KEY_BOOK_INFO,
        BookSettings.KEY_HIGHLIGHT_CONTEXT, BookSettings.KEY_DICTIONARY_CONTEXT,
        BookSettings.KEY_TOOL_EFFORT, BookSettings.KEY_WEB_EFFORT,
    }), BookSettings.showChatBehaviorConfig))
    addButton(subScreenRow(_("Privacy"), groupCount({
        BookSettings.KEY_HIGHLIGHTS_SHARING, BookSettings.KEY_ANNOTATIONS_SHARING,
        BookSettings.KEY_NOTEBOOK_SHARING, BookSettings.KEY_TEXT_EXTRACTION,
    }), BookSettings.showPrivacyConfig))
    addButton(subScreenRow(_("Identity"), groupCount({
        BookSettings.KEY_AI_TITLE, BookSettings.KEY_AI_AUTHOR,
    }), BookSettings.showIdentityConfig))
    addButton(subScreenRow(_("Quiz settings"), groupCount({ BookSettings.KEY_QUIZ }),
        BookSettings.showQuizConfig))
    addButton(subScreenRow(_("Languages"), groupCount({
        BookSettings.KEY_RESPONSE_LANG, BookSettings.KEY_TRANSLATION_LANG,
        BookSettings.KEY_DICTIONARY_LANG,
    }), BookSettings.showLanguageConfig))
    flushPair()

    -- Surface customizations: count deviations from global, offer a one-tap reset.
    -- Without this, sticky per-book overrides are easy to forget (and then global changes
    -- appear not to take effect for this book).
    local n_custom = BookSettings.countCustomized(doc_settings)
    if n_custom > 0 then
        addFullRow({ text = _("Reset book settings"), callback = function()
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = _("Reset all KOAssistant settings for this book to follow the global defaults?"),
                ok_text = _("Reset"),
                ok_callback = function()
                    BookSettings.resetBook(doc_settings)
                    syncConfig()
                    reopen()
                end,
            })
        end })
    end
    addFullRow({ text = _("Close"), id = "close", callback = function()
        closeDialog()
        if on_close then on_close() end
    end })

    local title = (n_custom > 0) and T(_("Book Settings (%1 customized)"), n_custom) or _("Book Settings")
    dialog = ButtonDialog:new{ title = title, buttons = buttons,
        tap_close_callback = function() dialog = nil; if on_close then on_close() end end }
    UIManager:show(dialog)
end

--- Per-book CHAT BEHAVIOR dials — a sub-screen of Book Settings (2026-08-12 regrouping;
-- the flat screen ran 13 "AI behavior" rows). Every row but Book info opens a SHARED
-- scope-aware picker on the book tab (seam 2 / consolidation P2) — the same dialogs
-- as the chip holds and QS tiles. The effort dials have first-class rows since P3
-- (deviation 12); Book info keeps a local picker (no shared sibling yet).
-- @param opts table: { plugin, ui, document_path, on_close }
function BookSettings.showChatBehaviorConfig(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close

    local doc_settings = resolveDocSettings(ui, opts.document_path)
    if not doc_settings then return end

    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}

    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function syncConfig()
        if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
    end
    local function dot(active) return active and "● " or "○ " end
    -- P4: follow-global rows carry the effective global value
    local function boolLabel(v, global_on)
        if v == true then return _("On")
        elseif v == false then return _("Off") end
        return T(_("Follow global (%1)"), global_on and _("On") or _("Off"))
    end

    -- Shared scope-aware pickers (seam 2), opened on the book tab; back here on
    -- close. `extra` merges picker-specific opts (showEffortPicker's kind).
    local function sharedPicker(show_fn, extra)
        closeDialog()
        local picker_opts = {
            plugin = plugin, ui = ui, document_path = opts.document_path,
            target_override = "book",
            on_close = function() BookSettings.showChatBehaviorConfig(opts) end,
        }
        if extra then
            for k, v in pairs(extra) do picker_opts[k] = v end
        end
        show_fn(picker_opts)
    end

    -- Book-info level: label + sub-picker (None / Title & author / +position)
    local function bookInfoLabel(v)
        if v == "none" then return _("None")
        elseif v == "title" then return _("Title only")
        elseif v == "full" then return _("Title, author & position")
        elseif v == "basic" then return _("Title & author") end
        return _("Follow global")
    end
    local function showBookInfoSubPicker()
        closeDialog()
        local cur = doc_settings:readSetting(BookSettings.KEY_BOOK_INFO)  -- nil | "none" | "basic" | "full"
        local picker
        local function setVal(val)
            doc_settings:saveSetting(BookSettings.KEY_BOOK_INFO, val)
            doc_settings:flush()
            syncConfig()
            UIManager:close(picker)
            BookSettings.showChatBehaviorConfig(opts)
        end
        local rows = {
            {{ text = dot(cur == nil) .. T(_("Follow global (%1)"), bookInfoLabel(features.book_info_in_chat or "basic")),
                callback = function() setVal(nil) end }},
            {{ text = dot(cur == "none") .. _("None"), callback = function() setVal("none") end }},
            {{ text = dot(cur == "title") .. _("Title only"), callback = function() setVal("title") end }},
            {{ text = dot(cur == "basic") .. _("Title & author"), callback = function() setVal("basic") end }},
            {{ text = dot(cur == "full") .. _("Title, author & position"), callback = function() setVal("full") end }},
            {{ text = _("Cancel"), id = "close",
                callback = function() UIManager:close(picker); BookSettings.showChatBehaviorConfig(opts) end }},
        }
        picker = ButtonDialog:new{ title = _("Book info in chat (this book)"), buttons = rows,
            tap_close_callback = function() BookSettings.showChatBehaviorConfig(opts) end }
        UIManager:show(picker)
    end

    local function contextRowLabel(v, global_mode)
        if v == nil then
            return T(_("Follow global (%1)"), BookSettings.contextModeLabel(global_mode))
        end
        return BookSettings.contextModeLabel(v)
    end
    -- AI Book Tools: On/Off label (legacy posture strings read through)
    local function toolsRowLabel(v)
        local on = toolsValueOn(v)
        if on == nil then
            return T(_("Follow global (%1)"),
                BookSettings.resolveBookTools(nil, features) and _("On") or _("Off"))
        end
        return on and _("On") or _("Off")
    end

    -- Effort dials as first-class rows (consolidation P3, deviation 12 — they
    -- were only reachable through the Tools/Web pickers' inner rows, yet their
    -- keys already counted toward this group's badge)
    local tool_effort = doc_settings:readSetting(BookSettings.KEY_TOOL_EFFORT)
    local web_effort = doc_settings:readSetting(BookSettings.KEY_WEB_EFFORT)

    local book_info_v = doc_settings:readSetting(BookSettings.KEY_BOOK_INFO)
    local buttons = {
        {{ text = T(_("AI Book Tools: %1"), toolsRowLabel(doc_settings:readSetting(BookSettings.KEY_TOOLS))),
            callback = function() sharedPicker(BookSettings.showToolsPosture) end }},
        {{ text = T(_("Lookup effort: %1"),
                tool_effort and BookSettings.toolEffortLabel(tool_effort)
                    or T(_("Follow global (%1)"),
                        BookSettings.toolEffortLabel(features.tool_lookup_effort or "standard"))),
            callback = function() sharedPicker(BookSettings.showEffortPicker, { kind = "tool" }) end }},
        {{ text = T(_("Web search: %1"), boolLabel(doc_settings:readSetting(BookSettings.KEY_WEB_SEARCH),
                features.enable_web_search == true)),
            callback = function() sharedPicker(BookSettings.showWebSearch) end }},
        {{ text = T(_("Search depth: %1"),
                web_effort and BookSettings.webEffortLabel(web_effort)
                    or T(_("Follow global (%1)"),
                        BookSettings.webEffortLabel(features.web_search_effort or "standard"))),
            callback = function() sharedPicker(BookSettings.showEffortPicker, { kind = "web" }) end }},
        {{ text = T(_("Quick answer default: %1"), boolLabel(doc_settings:readSetting(BookSettings.KEY_QUICK_ANSWER),
                features.quick_answer_default == true)),
            callback = function() sharedPicker(BookSettings.showQuickAnswerDefault) end }},
        {{ text = T(_("Book info: %1"),
                book_info_v and bookInfoLabel(book_info_v)
                    or T(_("Follow global (%1)"), bookInfoLabel(features.book_info_in_chat or "basic"))),
            callback = showBookInfoSubPicker }},
        {{ text = T(_("Highlight context: %1"), contextRowLabel(doc_settings:readSetting(BookSettings.KEY_HIGHLIGHT_CONTEXT),
                features.highlight_context_mode or "none")),
            callback = function() sharedPicker(BookSettings.showHighlightContext) end }},
        {{ text = T(_("Dictionary context: %1"), contextRowLabel(doc_settings:readSetting(BookSettings.KEY_DICTIONARY_CONTEXT),
                features.dictionary_context_mode or "sentence")),
            callback = function() sharedPicker(BookSettings.showDictionaryContext) end }},
        {{ text = _("Close"), id = "close", callback = function()
            closeDialog()
            if on_close then on_close() end
        end }},
    }

    dialog = ButtonDialog:new{ title = _("Chat behavior (this book)"), buttons = buttons,
        tap_close_callback = function() dialog = nil; if on_close then on_close() end end }
    UIManager:show(dialog)
end

--- Per-book X-RAY dials — a sub-screen of Book Settings (consolidation P3,
-- 2026-08-16): the Automatic X-Ray tri-state and the promotion hold move here
-- from the root screen (Q1b), and the previously popup-only keys (coverage
-- goal, checkpoint spacing, the 4 marking overrides) get first-class rows — no
-- per-book X-Ray key is reachable only through an X-Ray popup anymore. Marking
-- rows open the canonical two-layer pickers (P2); goal and promotion are
-- book-only by design (no global sibling exists). Spacing/goal edits only
-- shape rungs planned from now on — plans start at the ladder top.
-- @param opts table: { plugin, ui, document_path, on_close }
function BookSettings.showXrayConfig(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close

    local doc_settings = resolveDocSettings(ui, opts.document_path)
    if not doc_settings then return end

    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}

    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function reopen()
        closeDialog()
        BookSettings.showXrayConfig(opts)
    end
    local function syncConfig()
        if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
    end
    local function dot(active) return active and "● " or "○ " end
    -- P4: follow-global rows carry the effective global value
    local function boolLabel(v, global_on)
        if v == true then return _("On")
        elseif v == false then return _("Off") end
        return T(_("Follow global (%1)"), global_on and _("On") or _("Off"))
    end
    local function pctLabel(s)
        if plugin and plugin._xraySpacingPctLabel then return plugin:_xraySpacingPctLabel(s) end
        local pct = (tonumber(s) or 0) * 100
        return pct % 1 == 0 and tostring(math.floor(pct)) or string.format("%.1f", pct)
    end

    -- The reader instance's document, ONLY when it is this book — the section
    -- picker and the page-count-derived spacing recommendation must never read
    -- another open book (Book Settings can target any book from hub surfaces).
    local book_file = opts.document_path or (ui and ui.document and ui.document.file)
    local open_here = (ui and ui.document and ui.document.file and book_file
        and require("koassistant_doc_settings").samePath(ui.document.file, book_file)) or false

    -- Canonical marking pickers (P2), opened on the book tab; back here on close.
    local function markingPicker(kind)
        closeDialog()
        BookSettings.showXrayMarkingPicker({
            plugin = plugin, ui = ui, document_path = opts.document_path,
            kind = kind, target_override = "book",
            on_close = function() BookSettings.showXrayConfig(opts) end,
        })
    end

    local buttons = {}

    -- Tri-state Automatic X-Ray (§7 P1): On = create + update + promotion for
    -- this book, standalone — no global master required. Page-based books get
    -- the honest no-effect marker (auto is flowing-only) instead of a gray row.
    table.insert(buttons, {{ text = T(_("Automatic X-Ray: %1"),
            BookSettings.xrayAutoLabel(doc_settings, features))
            .. (isPageBased(ui, opts.document_path) and (" " .. _("(no effect: page-based book)")) or ""),
        callback = function()
            closeDialog()
            BookSettings.showXrayAutoPicker({
                plugin = plugin, ui = ui, document_path = opts.document_path,
                on_change = function()
                    syncConfig()
                    -- Refresh the page-turn pre-filter so the change takes effect this session
                    if plugin and plugin._refreshXrayAutoState then plugin:_refreshXrayAutoState() end
                    reopen()
                end,
                on_cancel = reopen,
            })
        end }})

    -- §5 (51g): the promotion hold as a first-class pick — before this row it
    -- was only ever set as a side effect of an install choice, which the device
    -- round found mysterious. Mechanical only: which built version installs;
    -- prompts and build cadence untouched. Book-only by design (P3 deviation 5:
    -- no global sibling — the "default" marker on the nil row is its reset).
    table.insert(buttons, {{ text = T(_("X-Ray updates: %1"),
            BookSettings.xrayPromotionHold(doc_settings)
                and _("Follow my position") or _("Newest first")),
        callback = function()
            closeDialog()
            local hold = BookSettings.xrayPromotionHold(doc_settings)
            local picker
            local function pickHold(on)
                if on then
                    doc_settings:saveSetting(BookSettings.KEY_XRAY_PROMOTION, "position")
                else
                    doc_settings:delSetting(BookSettings.KEY_XRAY_PROMOTION)
                end
                doc_settings:flush()
                syncConfig()
                -- Let an open book's promotion re-evaluate now (safe no-op otherwise)
                if plugin and plugin._scheduleXrayLadderPromotion then
                    plugin:_scheduleXrayLadderPromotion()
                end
                UIManager:close(picker)
                BookSettings.showXrayConfig(opts)
            end
            local xr_title = _("X-Ray updates (this book)")
            if (BookSettings.resolveXrayPosture(doc_settings, features)) == "track" then
                -- Research labelling rule applied here too: under spoiler
                -- protection updates follow the position regardless — say so,
                -- keep the stored pick editable.
                xr_title = xr_title .. "\n"
                    .. _("Spoiler protection is on: updates follow your position regardless of this pick.")
            end
            local rows = {
                {{ text = dot(not hold) .. _("Newest first (default: install checkpoints as they are built)"),
                    callback = function() pickHold(false) end }},
                {{ text = dot(hold) .. _("Follow my reading position"),
                    callback = function() pickHold(true) end }},
                {{ text = _("Cancel"), id = "close",
                    callback = function() UIManager:close(picker); BookSettings.showXrayConfig(opts) end }},
            }
            picker = ButtonDialog:new{ title = xr_title, buttons = rows,
                tap_close_callback = function() BookSettings.showXrayConfig(opts) end }
            UIManager:show(picker)
        end }})

    -- Coverage goal (creation-chooser rounds 21/23: a BOOK property bounding
    -- the auto scheduler; target picks in the create/extend form store it,
    -- whole-book picks clear it). First-class row so the bound is visible and
    -- clearable without opening the form; picking a NEW section target needs
    -- this book open (TOC).
    local goal = tonumber(doc_settings:readSetting(BookSettings.KEY_XRAY_GOAL))
    if goal and (goal <= 0.01 or goal >= 0.995) then goal = nil end
    -- "Build up to" (P5 rename, maintainer found "Coverage goal" opaque): the
    -- row is the bound on automatic building, so say exactly that.
    table.insert(buttons, {{ text = T(_("Build up to: %1"),
            goal and T(_("%1%"), math.floor(goal * 100 + 0.5)) or _("Whole book")),
        callback = function()
            closeDialog()
            local picker
            local function setGoal(val)
                doc_settings:saveSetting(BookSettings.KEY_XRAY_GOAL, val)
                doc_settings:flush()
                syncConfig()
                if picker then UIManager:close(picker) end
                BookSettings.showXrayConfig(opts)
            end
            local rows = {
                {{ text = dot(goal == nil) .. _("Whole book (default)"),
                    callback = function() setGoal(nil) end }},
            }
            if open_here and plugin and plugin._showSectionPicker then
                rows[#rows + 1] = {{ text = dot(goal ~= nil)
                        .. (goal and T(_("To the end of a section… (now %1%)"), math.floor(goal * 100 + 0.5))
                            or _("To the end of a section…")),
                    callback = function()
                        UIManager:close(picker); picker = nil
                        plugin:_showSectionPicker(nil, {
                            title = _("Build the X-Ray up to the end of…"),
                            on_cancel = function() BookSettings.showXrayConfig(opts) end,
                            on_select = function(entry)
                                -- Same ratio math as the create/extend form's target pick
                                local total = ui.document:getPageCount() or 0
                                local ratio = total > 0 and (entry.end_page or 0) / total or 0
                                if ratio >= 1.0 - 0.005 then
                                    setGoal(nil)  -- end of the book = whole book
                                elseif ratio > 0.01 then
                                    setGoal(ratio)
                                else
                                    BookSettings.showXrayConfig(opts)
                                end
                            end,
                        })
                    end }}
            end
            rows[#rows + 1] = {{ text = _("Cancel"), id = "close",
                callback = function() UIManager:close(picker); BookSettings.showXrayConfig(opts) end }}
            local title = _("Build the X-Ray up to (this book)") .. "\n"
                .. _("The limit for automatic building: checkpoints stop here until you raise it. It exists so a section target picked in the create/extend form keeps bounding automatic building afterwards. Whole book = no limit.")
            if not open_here then
                title = title .. "\n" .. _("Open the book to pick a section target.")
            end
            picker = ButtonDialog:new{ title = title, buttons = rows,
                tap_close_callback = function() BookSettings.showXrayConfig(opts) end }
            UIManager:show(picker)
        end }})

    -- Categories for NEW X-Rays (presets v0.21): the sticky per-book pick the
    -- create/rebuild paths read (book > global default > full). First-class
    -- here so closed books can set it before their first build (the creation
    -- chooser's button needs the form).
    local cat_sel, cat_layer = BookSettings.resolveXrayCategories(doc_settings, features)
    table.insert(buttons, {{ text = T(_("New X-Ray categories: %1"),
            cat_layer == "book" and BookSettings.xrayCategoriesLabel(cat_sel)
                or T(_("Follow global (%1)"), BookSettings.xrayCategoriesLabel(cat_sel))),
        callback = function()
            closeDialog()
            BookSettings.showXrayCategoriesPicker({
                ui = ui, document_path = opts.document_path, plugin = plugin,
                on_close = function()
                    syncConfig()
                    BookSettings.showXrayConfig(opts)
                end,
            })
        end }})

    -- Checkpoint spacing (spacing slice): the sticky per-book override, edited
    -- through the shared picker (P2 dots + reset). The recommendation falls
    -- back to the formula default when this book isn't the open one (the
    -- picker has no page count to size from).
    local sp_override = BookSettings.xraySpacingOverride(doc_settings)
    table.insert(buttons, {{ text = T(_("Checkpoint spacing: %1"),
            sp_override and T(_("every %1%"), pctLabel(sp_override)) or _("Recommended")),
        callback = function()
            if not (plugin and plugin._showXraySpacingPicker) then return end
            closeDialog()
            local cur
            if open_here and plugin._xrayLadderSpacing then
                cur = plugin:_xrayLadderSpacing()
            else
                cur = sp_override or require("koassistant_xray_auto").ladderSpacingFor(nil)
            end
            plugin:_showXraySpacingPicker{
                current = cur,
                override = sp_override,
                title = _("Checkpoint spacing for this book:"),
                on_pick = function(s)
                    doc_settings:saveSetting(BookSettings.KEY_XRAY_SPACING, s)
                    doc_settings:flush()
                    syncConfig()
                    BookSettings.showXrayConfig(opts)
                end,
                on_reset = function()
                    doc_settings:saveSetting(BookSettings.KEY_XRAY_SPACING, nil)
                    doc_settings:flush()
                    syncConfig()
                    BookSettings.showXrayConfig(opts)
                end,
                on_back = function() BookSettings.showXrayConfig(opts) end,
            }
        end }})

    -- Marking overrides (P2 canonical pickers — the same four the X-Ray
    -- popup's "Marking & lookup" shortcut opens, homed here)
    local b_marking = doc_settings:readSetting(BookSettings.KEY_XRAY_MARKING)
    local b_density = doc_settings:readSetting(BookSettings.KEY_XRAY_MARKING_DENSITY)
    local b_families = doc_settings:readSetting(BookSettings.KEY_XRAY_MARKING_FAMILIES)
    local b_tap = doc_settings:readSetting(BookSettings.KEY_XRAY_MARKING_TAP)
    table.insert(buttons, {{ text = T(_("Passive marking: %1"),
            boolLabel(b_marking, features.xray_marking ~= false)),
        callback = function() markingPicker("enabled") end }})
    table.insert(buttons, {{ text = T(_("Marking density: %1"),
            b_density and BookSettings.xrayMarkingDensityLabel(b_density)
                or T(_("Follow global (%1)"),
                    BookSettings.xrayMarkingDensityLabel(features.xray_marking_density or "10"))),
        callback = function() markingPicker("density") end }})
    table.insert(buttons, {{ text = T(_("Entities to mark: %1"),
            b_families and BookSettings.xrayMarkingFamiliesLabel(b_families)
                or T(_("Follow global (%1)"),
                    BookSettings.xrayMarkingFamiliesLabel(features.xray_marking_families or "all"))),
        callback = function() markingPicker("families") end }})
    table.insert(buttons, {{ text = T(_("Tap marked words: %1"),
            boolLabel(b_tap, features.xray_marking_tap ~= false)),
        callback = function() markingPicker("tap") end }})
    -- Round 3 (maintainer: "why are they not the same pattern"): Upcoming
    -- Entities rides the canonical two-layer picker like its marking siblings
    local b_ahead = doc_settings:readSetting(BookSettings.KEY_XRAY_AHEAD)
    table.insert(buttons, {{ text = T(_("Upcoming entities: %1"),
            boolLabel(b_ahead, features.xray_show_ahead_entities ~= false)),
        callback = function() markingPicker("ahead") end }})
    -- B269: the two card-content dials
    local b_acard = doc_settings:readSetting(BookSettings.KEY_XRAY_AHEAD_CARD)
    table.insert(buttons, {{ text = T(_("Upcoming entity cards: %1"),
            b_acard and BookSettings.xrayAheadCardLabel(b_acard)
                or T(_("Follow global (%1)"),
                    BookSettings.xrayAheadCardLabel(features.xray_ahead_card))),
        callback = function() markingPicker("ahead_card") end }})
    local b_len = doc_settings:readSetting(BookSettings.KEY_XRAY_CARD_LENGTH)
    table.insert(buttons, {{ text = T(_("Card shows: %1"),
            b_len and BookSettings.xrayCardLengthLabel(b_len)
                or T(_("Follow global (%1)"),
                    BookSettings.xrayCardLengthLabel(features.xray_card_length))),
        callback = function() markingPicker("card_length") end }})
    -- Round 5 (maintainer: "yes per book"): the two lookup-side settings too
    local b_int = doc_settings:readSetting(BookSettings.KEY_XRAY_INTERCEPT)
    table.insert(buttons, {{ text = T(_("Matching selections open entries: %1"),
            boolLabel(b_int, features.xray_selection_intercept ~= false)),
        callback = function() markingPicker("intercept") end }})
    local b_card = doc_settings:readSetting(BookSettings.KEY_XRAY_CARD)
    local g_card = BookSettings.xrayCardModeLabel(
        features.xray_card_landing == false and "full"
        or features.xray_card_style == "popup" and "popup" or "footnote")
    table.insert(buttons, {{ text = T(_("Exact hits open: %1"),
            b_card and BookSettings.xrayCardModeLabel(b_card)
                or T(_("Follow global (%1)"), g_card)),
        callback = function() markingPicker("card") end }})

    table.insert(buttons, {{ text = _("Close"), id = "close", callback = function()
        closeDialog()
        if on_close then on_close() end
    end }})

    dialog = ButtonDialog:new{ title = _("X-Ray (this book)"), buttons = buttons,
        tap_close_callback = function() dialog = nil; if on_close then on_close() end end }
    UIManager:show(dialog)
end

--- Per-book PRIVACY overrides — a sub-screen of Book Settings. Allow/Deny beat the
-- global Privacy & Data toggles for THIS book (deny also beats trusted providers);
-- per-action flags still apply on top (double-gating). Implications ride the
-- resolver, same as the globals: allow-annotations implies allow-highlights,
-- deny-highlights implies deny-annotations.
-- @param opts table: { plugin, ui, document_path, on_close }
function BookSettings.showPrivacyConfig(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close

    local doc_settings = resolveDocSettings(ui, opts.document_path)
    if not doc_settings then return end

    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}

    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function syncConfig()
        if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
    end
    local function dot(active) return active and "● " or "○ " end
    -- P4: follow-global rows carry the effective global value
    local function boolLabel(v, global_on)
        if v == true then return _("On")
        elseif v == false then return _("Off") end
        return T(_("Follow global (%1)"), global_on and _("On") or _("Off"))
    end

    -- Tri-state picker (Follow global / On / Off) for one privacy key.
    local function showBoolSubPicker(key, dialog_title, global_on)
        closeDialog()
        local cur = doc_settings:readSetting(key)  -- true | false | nil
        local picker
        local function pick(val)
            doc_settings:saveSetting(key, val)
            doc_settings:flush()
            syncConfig()
            UIManager:close(picker)
            BookSettings.showPrivacyConfig(opts)
        end
        local rows = {
            {{ text = dot(cur == nil) .. T(_("Follow global (%1)"), global_on and _("On") or _("Off")),
                callback = function() pick(nil) end }},
            {{ text = dot(cur == true) .. _("On"), callback = function() pick(true) end }},
            {{ text = dot(cur == false) .. _("Off"), callback = function() pick(false) end }},
            {{ text = _("Cancel"), id = "close",
                callback = function() UIManager:close(picker); BookSettings.showPrivacyConfig(opts) end }},
        }
        picker = ButtonDialog:new{ title = dialog_title, buttons = rows,
            tap_close_callback = function() BookSettings.showPrivacyConfig(opts) end }
        UIManager:show(picker)
    end

    local buttons = {
        {{ text = T(_("Highlights sharing: %1"), boolLabel(doc_settings:readSetting(BookSettings.KEY_HIGHLIGHTS_SHARING),
                features.enable_highlights_sharing == true or features.enable_annotations_sharing == true)),
            callback = function()
                showBoolSubPicker(BookSettings.KEY_HIGHLIGHTS_SHARING,
                    _("Highlights sharing (this book)"),
                    features.enable_highlights_sharing == true or features.enable_annotations_sharing == true)
            end }},
        {{ text = T(_("Annotations sharing: %1"), boolLabel(doc_settings:readSetting(BookSettings.KEY_ANNOTATIONS_SHARING),
                features.enable_annotations_sharing == true)),
            callback = function()
                showBoolSubPicker(BookSettings.KEY_ANNOTATIONS_SHARING,
                    _("Annotations sharing (this book)"), features.enable_annotations_sharing == true)
            end }},
        {{ text = T(_("Notebook sharing: %1"), boolLabel(doc_settings:readSetting(BookSettings.KEY_NOTEBOOK_SHARING),
                features.enable_notebook_sharing == true)),
            callback = function()
                showBoolSubPicker(BookSettings.KEY_NOTEBOOK_SHARING,
                    _("Notebook sharing (this book)"), features.enable_notebook_sharing == true)
            end }},
        {{ text = T(_("Text extraction: %1"), boolLabel(doc_settings:readSetting(BookSettings.KEY_TEXT_EXTRACTION),
                features.enable_book_text_extraction == true)),
            callback = function()
                showBoolSubPicker(BookSettings.KEY_TEXT_EXTRACTION,
                    _("Text extraction (this book)"), features.enable_book_text_extraction == true)
            end }},
        -- The override rules, spelled out (device note 2026-08-13)
        {{ text = _("How overrides work…"), callback = function()
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("These override the global privacy toggles for this book. Deny always wins — even over trusted providers. Allow satisfies only the global gate: actions still need their own data-access settings. Allowing annotations implies highlights; denying highlights denies annotations."),
            })
        end }},
        {{ text = _("Close"), id = "close", callback = function()
            closeDialog()
            if on_close then on_close() end
        end }},
    }

    dialog = ButtonDialog:new{ title = _("Privacy (this book)"), buttons = buttons,
        tap_close_callback = function() dialog = nil; if on_close then on_close() end end }
    UIManager:show(dialog)
end

--- Per-book AI IDENTITY overrides — a sub-screen of Book Settings: what the AI sees
-- as this book's title/author. nil = use the book's real metadata; "" = send empty
-- (suppress entirely); any other string = that custom value.
-- @param opts table: { plugin, ui, document_path, on_close }
function BookSettings.showIdentityConfig(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close

    local doc_settings = resolveDocSettings(ui, opts.document_path)
    if not doc_settings then return end

    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function reopen()
        closeDialog()
        BookSettings.showIdentityConfig(opts)
    end
    local function syncConfig()
        if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
    end
    local function dot(active) return active and "● " or "○ " end

    -- Custom-value text input for an AI title/author override (stored as-is; "" = send empty,
    -- but that state is normally reached via the "Send empty" sub-picker option).
    local function editOverride(key, dialog_title)
        local InputDialog = require("ui/widget/inputdialog")
        local input
        input = InputDialog:new{
            title = dialog_title,
            input = doc_settings:readSetting(key) or "",
            input_hint = _("What the AI should see for this book"),
            buttons = {{
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        doc_settings:saveSetting(key, input:getInputText())
                        doc_settings:flush()
                        syncConfig()
                        UIManager:close(input)
                        reopen()
                    end,
                },
            }},
        }
        UIManager:show(input)
        input:onShowKeyboard()
    end

    -- Sub-picker for a tri-state metadata override: Use real metadata / Custom… / Send empty.
    local function showOverrideSubPicker(key, dialog_title, custom_input_title)
        closeDialog()
        local cur = doc_settings:readSetting(key)  -- nil | "" | string
        local picker
        local function setVal(val)
            doc_settings:saveSetting(key, val)
            doc_settings:flush()
            syncConfig()
            UIManager:close(picker)
            BookSettings.showIdentityConfig(opts)
        end
        local custom_text = (cur ~= nil and cur ~= "") and T(_("Custom: %1"), cur) or _("Custom…")
        local rows = {
            {{ text = dot(cur == nil) .. _("Use the book's real metadata"),
                callback = function() setVal(nil) end }},
            {{ text = dot(cur ~= nil and cur ~= "") .. custom_text,
                callback = function() UIManager:close(picker); editOverride(key, custom_input_title) end }},
            {{ text = dot(cur == "") .. _("Send empty"),
                callback = function() setVal("") end }},
            {{ text = _("Cancel"), id = "close",
                callback = function() UIManager:close(picker); BookSettings.showIdentityConfig(opts) end }},
        }
        picker = ButtonDialog:new{ title = dialog_title, buttons = rows,
            tap_close_callback = function() BookSettings.showIdentityConfig(opts) end }
        UIManager:show(picker)
    end

    -- nil = real metadata, "" = empty/suppressed, string = custom
    local function overrideLabel(v)
        if v == nil then return _("using metadata")
        elseif v == "" then return _("empty") end
        return v
    end
    local title_ov, author_ov = BookSettings.getMetadataOverride(doc_settings)

    local buttons = {
        {{ text = T(_("AI title: %1"), overrideLabel(title_ov)),
            callback = function()
                showOverrideSubPicker(BookSettings.KEY_AI_TITLE,
                    _("AI title (this book)"), _("Custom AI title"))
            end }},
        {{ text = T(_("AI author: %1"), overrideLabel(author_ov)),
            callback = function()
                showOverrideSubPicker(BookSettings.KEY_AI_AUTHOR,
                    _("AI author (this book)"), _("Custom AI author"))
            end }},
        {{ text = _("Close"), id = "close", callback = function()
            closeDialog()
            if on_close then on_close() end
        end }},
    }

    dialog = ButtonDialog:new{ title = _("Identity (this book)"), buttons = buttons,
        tap_close_callback = function() dialog = nil; if on_close then on_close() end end }
    UIManager:show(dialog)
end

-- Human labels for the quiz "Follow global (X)" rows.
local function quizDifficultyLabel(v)
    if v == "easy" then return _("Easy")
    elseif v == "hard" then return _("Hard") end
    return _("Medium")
end
local function quizLevelLabel(v)
    if v == "auto" then return _("Auto-detect")
    elseif v == 1 then return _("Top level (Level 1)")
    elseif v == 2 then return _("Level 2")
    elseif v == 3 then return _("Level 3")
    elseif v == "toc_filter" or v == "all" then return _("All TOC headings") end
    return _("Level 2")
end

--- Per-book QUIZ overrides — a sub-screen of Book Settings. Each row shows the per-book
-- value (or "Follow global (X)") and opens a small picker; "Follow global" clears that
-- field from the sparse KEY_QUIZ table. `enabled` is suppress-only (it can only turn the
-- chapter-end auto-quiz OFF for this book, never force it on past the global gate).
-- @param opts table: { plugin, ui, document_path, on_close }
function BookSettings.showQuizConfig(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close

    local doc_settings = resolveDocSettings(ui, opts.document_path)
    if not doc_settings then return end

    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}

    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function reopen()
        closeDialog()
        BookSettings.showQuizConfig(opts)
    end
    local function dot(active) return active and "● " or "○ " end

    -- Fresh read of the sparse per-book quiz table.
    local function bq() return doc_settings:readSetting(BookSettings.KEY_QUIZ) or {} end
    -- Set one field (nil clears it → follow global), then re-sync in-memory config.
    local function setField(field, value)
        BookSettings.setQuizField(doc_settings, field, value)
        if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
    end

    -- Tri-state picker (Follow global / On / Off) for a boolean field.
    local function showTriState(field, dialog_title, global_on)
        closeDialog()
        local cur = bq()[field]
        local picker
        local function setVal(v)
            UIManager:close(picker)
            setField(field, v)
            BookSettings.showQuizConfig(opts)
        end
        picker = ButtonDialog:new{ title = dialog_title, buttons = {
            {{ text = dot(cur == nil) .. T(_("Follow global (%1)"), global_on and _("On") or _("Off")),
                callback = function() setVal(nil) end }},
            {{ text = dot(cur == true) .. _("On"), callback = function() setVal(true) end }},
            {{ text = dot(cur == false) .. _("Off"), callback = function() setVal(false) end }},
            {{ text = _("Cancel"), id = "close",
                callback = function() UIManager:close(picker); BookSettings.showQuizConfig(opts) end }},
        },
        tap_close_callback = function() BookSettings.showQuizConfig(opts) end }
        UIManager:show(picker)
    end

    -- Option-list picker: "Follow global (X)" + each { value, label }.
    local function showOptions(field, dialog_title, global_label, options)
        closeDialog()
        local cur = bq()[field]
        local picker
        local function setVal(v)
            UIManager:close(picker)
            setField(field, v)
            BookSettings.showQuizConfig(opts)
        end
        local rows = {
            {{ text = dot(cur == nil) .. T(_("Follow global (%1)"), global_label),
                callback = function() setVal(nil) end }},
        }
        for _i, opt in ipairs(options) do
            local v = opt.value
            table.insert(rows, {{ text = dot(cur == v) .. opt.label, callback = function() setVal(v) end }})
        end
        table.insert(rows, {{ text = _("Cancel"), id = "close",
            callback = function() UIManager:close(picker); BookSettings.showQuizConfig(opts) end }})
        picker = ButtonDialog:new{ title = dialog_title, buttons = rows,
            tap_close_callback = function() BookSettings.showQuizConfig(opts) end }
        UIManager:show(picker)
    end

    -- Numeric spinner with a "Follow global" escape (clears the field on the extra button).
    local function showSpinner(field, dialog_title, vmin, vmax, default_val)
        closeDialog()
        local SpinWidget = require("ui/widget/spinwidget")
        UIManager:show(SpinWidget:new{
            title_text = dialog_title,
            value = bq()[field] or default_val,
            value_min = vmin,
            value_max = vmax,
            value_step = 1,
            ok_always_enabled = true,
            extra_text = _("Follow global"),
            extra_callback = function() setField(field, nil); reopen() end,
            callback = function(spin) setField(field, spin.value); reopen() end,
            cancel_callback = function() reopen() end,
        })
    end

    local cur = bq()
    -- P4: follow-global labels carry the effective global value
    local function follow(global_label)
        return T(_("Follow global (%1)"), global_label)
    end
    local function triLabel(v, global_on)
        if v == true then return _("On")
        elseif v == false then return _("Off") end
        return follow(global_on and _("On") or _("Off"))
    end
    local function numLabel(v, global_num)
        return (v == nil) and follow(tostring(global_num)) or tostring(v)
    end
    local function minPagesLabel(v)
        if v == 0 then return _("No minimum") end
        return T(_("%1 pages"), v)
    end
    local function minTimeLabel(v)
        if v == 0 then return _("No minimum") end
        return T(_("%1 min"), v)
    end
    local global_min_pages = features.quiz_min_chapter_pages or 5
    local global_min_time = features.quiz_min_chapter_time or 3

    -- `enabled` is suppress-only (the global gate runs before the per-book read in the
    -- page-turn hot path), so it's an honest two-state: Follow global / Off-for-this-book.
    -- It can silence the chapter-end auto-quiz for one book, never force it on past a
    -- globally-disabled quiz.
    local function enabledLabel(v)
        if v == false then return _("Off (this book)") end
        return follow(features.enable_chapter_quiz == true and _("On") or _("Off"))
    end

    local buttons = {
        {{ text = T(_("Chapter-end quiz: %1"), enabledLabel(cur.enabled)),
            callback = function()
                showOptions("enabled", _("Chapter-end quiz (this book)"),
                    features.enable_chapter_quiz == true and _("On") or _("Off"),
                    { { value = false, label = _("Off: never quiz this book") } })
            end }},
        {{ text = T(_("Question count: %1"), numLabel(cur.count, features.quiz_question_count or 8)),
            callback = function()
                showSpinner("count", _("Question count (this book)"), 3, 15,
                    features.quiz_question_count or 8)
            end }},
        {{ text = T(_("Difficulty: %1"), (cur.difficulty == nil)
                and follow(quizDifficultyLabel(features.quiz_difficulty or "medium"))
                or quizDifficultyLabel(cur.difficulty)),
            callback = function()
                showOptions("difficulty", _("Difficulty (this book)"),
                    quizDifficultyLabel(features.quiz_difficulty or "medium"), {
                        { value = "easy", label = _("Easy") },
                        { value = "medium", label = _("Medium") },
                        { value = "hard", label = _("Hard") },
                    })
            end }},
        {{ text = T(_("Multiple choice: %1"), triLabel(cur.mc, features.quiz_mc_enabled ~= false)),
            callback = function()
                showTriState("mc", _("Multiple choice (this book)"), features.quiz_mc_enabled ~= false)
            end }},
        {{ text = T(_("Short answer: %1"), triLabel(cur.sa, features.quiz_short_answer_enabled ~= false)),
            callback = function()
                showTriState("sa", _("Short answer (this book)"), features.quiz_short_answer_enabled ~= false)
            end }},
        {{ text = T(_("Discussion: %1"), triLabel(cur.essay, features.quiz_essay_enabled ~= false)),
            callback = function()
                showTriState("essay", _("Discussion (this book)"), features.quiz_essay_enabled ~= false)
            end }},
        {{ text = T(_("Chapter level: %1"), (cur.chapter_depth == nil)
                and follow(quizLevelLabel(features.quiz_chapter_depth or 2))
                or quizLevelLabel(cur.chapter_depth)),
            callback = function()
                showOptions("chapter_depth", _("Quiz chapter level (this book)"),
                    quizLevelLabel(features.quiz_chapter_depth or 2), {
                        { value = "auto", label = _("Auto-detect") },
                        { value = 1, label = _("Top level (Level 1)") },
                        { value = 2, label = _("Level 2") },
                        { value = 3, label = _("Level 3") },
                        { value = "toc_filter", label = _("All TOC headings") },
                    })
            end }},
        {{ text = T(_("Min chapter length: %1"), (cur.min_pages == nil)
                and follow(minPagesLabel(global_min_pages)) or minPagesLabel(cur.min_pages)),
            callback = function()
                showSpinner("min_pages", _("Min chapter length, pages (this book)"), 0, 30,
                    global_min_pages)
            end }},
        {{ text = T(_("Min reading time: %1"), (cur.min_minutes == nil)
                and follow(minTimeLabel(global_min_time)) or minTimeLabel(cur.min_minutes)),
            callback = function()
                showSpinner("min_minutes", _("Min reading time, minutes (this book)"), 0, 60,
                    global_min_time)
            end }},
        {{ text = _("Close"), id = "close", callback = function()
            closeDialog()
            if on_close then on_close() end
        end }},
    }

    dialog = ButtonDialog:new{ title = _("Quiz settings (this book)"), buttons = buttons,
        tap_close_callback = function() dialog = nil; if on_close then on_close() end end }
    UIManager:show(dialog)
end

--- Per-book TRANSLATION / DICTIONARY target-language overrides — a sub-screen of Book
-- Settings. Each row shows the per-book value (or "Follow global (X)") and opens a language
-- picker (Follow global / a language from the list / Custom… / Cancel). Stored values are
-- language ids (same as the global pickers), so the request pipeline treats them identically.
-- @param opts table: { plugin, ui, document_path, on_close }
function BookSettings.showLanguageConfig(opts)
    opts = opts or {}
    local plugin = opts.plugin
    local ui = opts.ui
    local on_close = opts.on_close

    local doc_settings = resolveDocSettings(ui, opts.document_path)
    if not doc_settings then return end

    local features = plugin and plugin.settings and plugin.settings:readSetting("features") or {}

    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog); dialog = nil end
    end
    local function syncConfig()
        if plugin and plugin.updateConfigFromSettings then plugin:updateConfigFromSettings() end
    end
    local function dot(active) return active and "● " or "○ " end

    -- Free-text custom language (matches the global picker's "Custom language…" input).
    local function editCustom(key, dialog_title)
        local InputDialog = require("ui/widget/inputdialog")
        local input
        input = InputDialog:new{
            title = dialog_title,
            input = doc_settings:readSetting(key) or "",
            input_hint = _("Language name (e.g. Spanish)"),
            buttons = {{
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local v = input:getInputText()
                        doc_settings:saveSetting(key, (v ~= "" and v) or nil)
                        doc_settings:flush()
                        syncConfig()
                        UIManager:close(input)
                        BookSettings.showLanguageConfig(opts)
                    end,
                },
            }},
        }
        UIManager:show(input)
        input:onShowKeyboard()
    end

    -- Language picker for one key: Follow global / each language / Custom… / Cancel.
    local function showLangPicker(key, dialog_title, global_display)
        closeDialog()
        local cur = doc_settings:readSetting(key)
        local picker
        local function setVal(v)
            doc_settings:saveSetting(key, v)
            doc_settings:flush()
            syncConfig()
            UIManager:close(picker)
            BookSettings.showLanguageConfig(opts)
        end
        local rows = {
            {{ text = dot(cur == nil or cur == "") .. T(_("Follow global (%1)"), global_display),
                callback = function() setVal(nil) end }},
        }
        for _i, id in ipairs(Languages.getAllIds()) do
            table.insert(rows, {{ text = dot(cur == id) .. Languages.getDisplay(id),
                callback = function() setVal(id) end }})
        end
        table.insert(rows, {{ text = _("Custom…"),
            callback = function() UIManager:close(picker); editCustom(key, dialog_title) end }})
        table.insert(rows, {{ text = _("Cancel"), id = "close",
            callback = function() UIManager:close(picker); BookSettings.showLanguageConfig(opts) end }})
        picker = ButtonDialog:new{ title = dialog_title, buttons = rows,
            tap_close_callback = function() BookSettings.showLanguageConfig(opts) end }
        UIManager:show(picker)
    end

    local function gdisp(v)
        if v == nil or v == "" then return _("primary language") end
        return Languages.getDisplay(v)
    end
    -- P4: follow-global rows carry the effective global value
    local function langLabel(v, global_display)
        if v == nil or v == "" then return T(_("Follow global (%1)"), global_display) end
        return Languages.getDisplay(v)
    end

    -- Effective global target languages (for the "Follow global (X)" hints).
    local SystemPrompts = require("prompts.system_prompts")
    local global_trans = SystemPrompts.getEffectiveTranslationLanguage({
        translation_use_primary = features.translation_use_primary,
        interaction_languages = features.interaction_languages,
        user_languages = features.user_languages,
        primary_language = features.primary_language,
        translation_language = features.translation_language,
    })
    local global_dict = SystemPrompts.getEffectiveDictionaryLanguage({
        dictionary_language = features.dictionary_language,
        translation_use_primary = features.translation_use_primary,
        interaction_languages = features.interaction_languages,
        user_languages = features.user_languages,
        primary_language = features.primary_language,
        translation_language = features.translation_language,
    })

    -- Global main response language (the "Always respond in X" directive's primary).
    local global_response = SystemPrompts.parseUserLanguages(
        features.interaction_languages or features.user_languages, features.primary_language)

    local cur_r = doc_settings:readSetting(BookSettings.KEY_RESPONSE_LANG)
    local cur_t = doc_settings:readSetting(BookSettings.KEY_TRANSLATION_LANG)
    local cur_d = doc_settings:readSetting(BookSettings.KEY_DICTIONARY_LANG)

    local buttons = {
        {{ text = T(_("AI response language: %1"), langLabel(cur_r, gdisp(global_response))),
            callback = function()
                showLangPicker(BookSettings.KEY_RESPONSE_LANG,
                    _("AI response language (this book)"), gdisp(global_response))
            end }},
        {{ text = T(_("Translation language: %1"), langLabel(cur_t, gdisp(global_trans))),
            callback = function()
                showLangPicker(BookSettings.KEY_TRANSLATION_LANG,
                    _("Translation language (this book)"), gdisp(global_trans))
            end }},
        {{ text = T(_("Dictionary language: %1"), langLabel(cur_d, gdisp(global_dict))),
            callback = function()
                showLangPicker(BookSettings.KEY_DICTIONARY_LANG,
                    _("Dictionary language (this book)"), gdisp(global_dict))
            end }},
        {{ text = _("Close"), id = "close", callback = function()
            closeDialog()
            if on_close then on_close() end
        end }},
    }

    dialog = ButtonDialog:new{ title = _("Languages (this book)"), buttons = buttons,
        tap_close_callback = function() dialog = nil; if on_close then on_close() end end }
    UIManager:show(dialog)
end

return BookSettings
