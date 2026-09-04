--[[--
Automatic X-Ray: the unified checkpoint engine's pure pieces + cross-instance
session state (docs/xray_background_plan.md + xray_ecosystem_plan.md item 23).

Grid math and gate helpers are pure (quiz_chapters precedent — no KOReader
deps, unit-testable). The module additionally holds file-local session state
that must survive ReaderUI plugin-instance teardown on book switch
(`last_attempt`, the in-flight flag, the subprocess cancel handle, the build
chain, and the session failure/success trace): per-instance `self._*` state
would reset the rate limit on every book hop and orphan the in-flight flag.
main.lua owns all event wiring and disk reads.
]]

local XrayAuto = {}

-- Defaults (xray_background_plan.md §10: threshold/cap/cooldown are user dials now;
-- these values back the schema defaults and any state without stamped dials)
XrayAuto.THRESHOLD = 0.05        -- min progress delta before an update is worth firing
XrayAuto.MAX_DELTA = 0.25        -- cap: bigger gaps stay manual (the popup shows size/cost)
XrayAuto.RATE_LIMIT_S = 15 * 60  -- min seconds between background attempts
XrayAuto.JUMP_GUARD_PAGES = 5    -- quiz pattern: a TOC jump moves many pages, a turn 1-3
XrayAuto.SCHEDULE_DELAY_S = 3    -- defer the fire off the page-turn tick
XrayAuto.CATCHUP_DELAY_S = 30    -- session-start catch-up delay (update-checker pattern)
-- (The flight WATCHDOG was retired 2026-08-05, maintainer: a kill is lossy —
-- the provider bills the request anyway — and slow is not stuck (#90 local
-- models; big one-shots). True hangs are rare and covered: the child's own
-- socket timeouts self-resolve dead connections, every in-progress state has
-- a tap-to-cancel row, and book close cancels the flight.)
XrayAuto.RETRY_DELAY_S = 60      -- item 45: single transient-failure retry per ladder step.
                                 -- Field specimen (2026-08-03): a Gemini 503 healed on a
                                 -- resume 76s later — one 60s retry makes that invisible.

-- Cross-instance session state (file-local module state, NOT self._*)
local last_attempt = nil   -- stamped at SCHEDULE time, not fire time
local in_flight = false
local in_flight_file = nil -- which book the flight belongs to (popup display scoping, T8)
local cancel_fn = nil
local last_failure = nil   -- { file = path, message = string }
local last_ladder_stop = nil -- { file, step, total, kind } — why the chain last paused (item 45)
local session_updates = 0
local cancelled = false    -- set when an actual flight was cancelled (close/tap-to-cancel)
local discarded = false    -- set by the completion guard when it rejects the write

--- Resolve the user dials (schema: Reading & Library → X-Ray) into gate values.
--- Pure; fallbacks MUST match the schema defaults (5% / 25% / 15 min). An inverted
--- window (max < min) clamps to max = min rather than silently never firing.
--- @param features table settings features (may be nil)
--- @return table { min_gap, max_gap, cooldown_s }
function XrayAuto.dialsFromFeatures(features)
  local f = features or {}
  local min_gap = (tonumber(f.xray_auto_min_gap) or 5) / 100
  local max_gap = (tonumber(f.xray_auto_max_gap) or 25) / 100
  if max_gap < min_gap then max_gap = min_gap end
  return {
    min_gap = min_gap,
    max_gap = max_gap,
    cooldown_s = (tonumber(f.xray_auto_cooldown) or 15) * 60,
  }
end

-- (Round 21, unified checkpoint engine — plan item 23: the old shouldFire
-- threshold/cap gate matrix is RETIRED with the to-position auto-update path.
-- The scheduler's rule is now the one-ahead invariant, checked in
-- main.lua:_xrayAutoOnPageUpdate against in-memory state; the jump guard,
-- cooldown, and in-flight gates survive as the pieces below.)

--- Cooldown gate for the auto scheduler (stamped at SCHEDULE time via
--- markScheduled, same as before). Pure over module state + arguments.
--- @param cooldown_s number|nil seconds (nil = RATE_LIMIT_S)
--- @param now number os.time()
--- @return boolean true when a new schedule is allowed
function XrayAuto.cooldownElapsed(cooldown_s, now)
  if not last_attempt or not now then return true end
  return (now - last_attempt) >= (tonumber(cooldown_s) or XrayAuto.RATE_LIMIT_S)
end

--- The auto scheduler's work list (round 21): every missing grid point up to
--- and including ONE past the reader — the one-ahead invariant. Pure prefix
--- slice over an already-planned grid; the parallel sparse labels array keeps
--- its indices (a prefix never shifts them).
--- @param rungs table ascending grid targets (planBuildRungs/snap output)
--- @param position number reader position 0..1
--- @param labels table|nil sparse parallel chapter labels
--- @return table truncated rungs, table truncated labels
function XrayAuto.truncateToOneAhead(rungs, position, labels)
  local pos = tonumber(position) or 0
  local out, out_labels = {}, {}
  for idx, t in ipairs(rungs or {}) do
    out[#out + 1] = t
    if labels and labels[idx] then out_labels[#out] = labels[idx] end
    if t > pos + XrayAuto.LADDER_TOLERANCE then break end
  end
  return out, out_labels
end

--- Stamp the rate limit at SCHEDULE time (several page turns can pass the gates
--- inside the deferral window; only the first may schedule).
--- B261: the inverse of markScheduled. The stamp was set at every schedule
--- AND chain start but never cleared, so a completed chain left the
--- page-turn trigger declining silently for a whole cooldown. Cooldown now
--- means "minimum time between ATTEMPTS after a decline/failure/cancel":
--- a chain that completes clears it, and an explicit enable clears it.
function XrayAuto.clearScheduled()
  last_attempt = nil
end

function XrayAuto.markScheduled(now)
  last_attempt = now
end

function XrayAuto.beginFlight(file)
  in_flight = true
  in_flight_file = file
end

function XrayAuto.endFlight()
  in_flight = false
  in_flight_file = nil
  cancel_fn = nil
end

function XrayAuto.isInFlight()
  return in_flight
end

--- Which book the current flight belongs to (nil when idle or unknown). The
--- gate stays global — one background request at a time — but popup DISPLAY
--- scopes to the file so another book's flight can't gray out this book's rows.
function XrayAuto.inFlightFile()
  return in_flight_file
end

--- Store the cancel handle returned by the silent request path (gpt_query
--- `config._register_cancel`). Called from inside the request machinery.
function XrayAuto.registerCancel(fn)
  cancel_fn = fn
end

--- Cancel a background request in flight (document close, tap-to-cancel rows).
--- Safe no-op when idle. The completion guard makes a straggler write
--- impossible either way.
function XrayAuto.cancelInFlight()
  if cancel_fn or in_flight then
    -- Only a real cancellation marks the flag — an idle close must not poison the
    -- NEXT fire's outcome classification
    cancelled = true
  end
  if cancel_fn then
    local fn = cancel_fn
    cancel_fn = nil
    pcall(fn)
  end
  in_flight = false
  in_flight_file = nil
end

--- Consume-once outcome markers so the fire callback classifies results honestly
--- (plan §6: the visible trace must not record a guard-discard as a success, nor a
--- book-close cancel as a failure).
function XrayAuto.markDiscarded()
  discarded = true
end

function XrayAuto.consumeOutcomeFlags()
  local c, d = cancelled, discarded
  cancelled, discarded = false, false
  return c, d
end

function XrayAuto.recordFailure(file, message)
  last_failure = { file = file, message = message }
end

function XrayAuto.clearFailure()
  last_failure = nil
end

--- Session-scoped "last auto-update failed" trace for the scope popup.
--- @param file string book path to match
--- @return string|nil failure message
function XrayAuto.lastFailure(file)
  if last_failure and last_failure.file == file then
    return last_failure.message or "failed"
  end
  return nil
end

function XrayAuto.recordSuccess(file)
  session_updates = session_updates + 1
  if last_failure and last_failure.file == file then
    last_failure = nil
  end
end

--- Classify a request-failure message into a short reason kind (item 45).
--- Wire-neutral: matches HTTP status classes and generic phrasings, never one
--- provider's exact wording. Pure.
---
--- The size classes CONSULT the parsers that already own those wordings rather
--- than re-matching their sentences (audit B2b, F36): the string handed in has
--- been through decorateRequestError, so the retry decision used to be driven by
--- the plugin's own advice paragraph and came out exactly inverted (Cerebras's
--- per-minute refusal graded "rate limited" and bought a useless 60-second
--- retry, only because the appended tip contained the words "rate limit"; Groq's
--- #106 refusal graded "other" and named no reason at all). An admission refusal
--- and a context/output-cap 400 are deterministic, so transient is false: the
--- retry would be a guaranteed second failure.
--- @param err string|nil The error text (handler-formatted, e.g. "gemini/…: HTTP 503: …")
--- @return string kind "aborted"|"too_large"|"overloaded"|"rate_limited"|"server_error"|"timeout"|"network"|"bad_json"|"other"
--- @return boolean transient True when a short wait plausibly heals it (retry-worthy)
function XrayAuto.classifyStopReason(err)
  local text = type(err) == "string" and err:lower() or ""
  -- The plugin's own pre-send abort sentinels (koassistant_dialogs.lua raises
  -- "background: …" BEFORE any request goes out): a deliberate local skip, not a
  -- model failure. Same test the scheduled path already uses. Without it
  -- "background: delta truncated" matched the bare "truncated" below and was
  -- reported to the reader as an "unusable response" for a request never sent.
  if text:find("^background:") then
    return "aborted", false
  end
  -- Inline requires: both modules are pure and loadable from here, and this file
  -- deliberately keeps no file-level dependency on the api/constraints layer.
  local RateLimits = require("koassistant_rate_limits")
  local ModelConstraints = require("model_constraints")
  -- A "Used N" count means the bucket is spent and refills with time (a
  -- per-minute burst, or a daily bucket that also says "reduce your message
  -- size"): never terminal, whatever else the wording says.
  local refusal_kind = RateLimits.refusalKind(err)
  if not RateLimits.hasUsedCount(err) and (refusal_kind == "admission"
      or ModelConstraints.parseMaxTokensError(err)
      or ModelConstraints.isSizeError(err)) then
    return "too_large", false
  end
  if text:find("http 503", 1, true) or text:find("overload", 1, true)
      or text:find("high demand", 1, true) or text:find("capacity", 1, true) then
    return "overloaded", true
  end
  if text:find("http 429", 1, true) or text:find("rate limit", 1, true)
      or text:find("quota", 1, true) or text:find("resource_exhausted", 1, true) then
    return "rate_limited", true
  end
  if text:find("http 50%d") then
    return "server_error", true
  end
  if text:find("timed out", 1, true) or text:find("timeout", 1, true) then
    return "timeout", true
  end
  if text:find("connect", 1, true) or text:find("network", 1, true)
      or text:find("socket", 1, true) or text:find("ssl", 1, true)
      or text:find("wifi", 1, true) or text:find("resolve host", 1, true) then
    return "network", true
  end
  if text:find("not a valid x%-ray json") or text:find("json", 1, true)
      or text:find("truncated", 1, true) or text:find("rung not saved", 1, true) then
    return "bad_json", false
  end
  return "other", false
end

--- Session-scoped "why the checkpoint chain last paused" (item 45): recorded
--- on failure stops AND (2026-08-15, A5) explicit cancels and book-close
--- interruptions; cleared when a chain (re)starts for the file.
function XrayAuto.recordLadderStop(file, info)
  -- rebuild (2026-08-15): a PRE-SWAP rebuild chain that stops must resume as a
  -- rebuild — without the flag the resume row restarted it as a plain extend
  -- of the very lineage the rebuild was replacing
  last_ladder_stop = { file = file, step = info and info.step,
    total = info and info.total, kind = info and info.kind,
    rebuild = info and info.rebuild }
end

--- @return table|nil { step, total, kind } for this file
function XrayAuto.lastLadderStop(file)
  if last_ladder_stop and last_ladder_stop.file == file then
    return last_ladder_stop
  end
  return nil
end

function XrayAuto.sessionUpdateCount()
  return session_updates
end

--- Derive background-update eligibility from a fresh per-action "xray" cache entry
--- (the entry the update machinery and scope popup key off). Pure; caller does the
--- disk read. Mirrors the manual incremental path's skips (dialogs.lua): missing
--- entry, complete-track, ai_knowledge source, and legacy non-JSON caches never
--- background-update.
--- @param entry table|nil ActionCache.get(file, "xray") result
--- @param is_json_fn function (result_string) -> boolean  (XrayParser.isJSON)
--- @return boolean eligible, number|nil cached_progress
function XrayAuto.eligibilityFromEntry(entry, is_json_fn)
  if not entry or not entry.result then return false, nil end
  if entry.full_document then return false, nil end
  if entry.source_mode == "ai_knowledge" then return false, nil end
  if is_json_fn and not is_json_fn(entry.result) then return false, nil end
  local p = tonumber(entry.progress_decimal)
  if not p or p >= 1.0 then return false, nil end
  return true, p
end

-- ========================= Version ladder (create-ahead) =========================
-- xray_ecosystem_plan.md §5 decisions 10/11 + §6 slice 1 (ref #73 #90). Pure rung
-- math + the build-chain session state live here (same cross-instance rationale as
-- the flight state above); ladder file I/O lives in koassistant_action_cache.lua.

XrayAuto.LADDER_SPACING = 0.10   -- rung boundaries every 10% (baseline; formula below can widen OR narrow)
XrayAuto.LADDER_TOLERANCE = 0.005
-- Promotion reach (2026-08-25 device round, ref #90): a rung may install only
-- once the reader has REACHED its coverage. Rung positions are snapped to
-- three decimals, so half a snap unit is the whole allowance for "reached
-- exactly"; LADDER_TOLERANCE here installed rungs up to half a percent
-- (a few pages) ahead of the reader, and an alias folded from those pages
-- went live before the reader met it.
XrayAuto.PROMOTE_TOLERANCE = 0.0005
-- Build lag (2026-08-25, maintainer): the NEXT checkpoint starts building only
-- once the reader is this far PAST the newest built one, i.e. after it has
-- installed (PROMOTE_TOLERANCE) and the dedup ask has shown. The point is
-- that install and build are never simultaneous, and that the build bases
-- on the LIVE copy (edits ride into every later rung). A couple of page
-- turns; 1% felt like too many on device.
XrayAuto.BUILD_LAG = 0.003
XrayAuto.LADDER_MIN_RUNG_PAGES = 45  -- P2(a) floor: a rung must cover at least ~this many pages
                                     -- (round 10: 30 -> 45 — every rung pays a fixed re-send
                                     -- overhead, so short books get fewer, larger calls;
                                     -- 10% baseline now starts at 450pp, not 300)
XrayAuto.LADDER_MAX_RUNG_PAGES = 100 -- P2(a) v2 ceiling: one rung should not extract much more than this
XrayAuto.LADDER_MIN_SPACING = 0.05   -- call-count bound: never more than ~20 rungs, even on monster books
XrayAuto.LADDER_MAX_SPACING = 0.50   -- tiny books still get a midpoint + final rung
XrayAuto.LADDER_SNAP_WINDOW = 0.03   -- P3: chapter-end snap distance (±3%; narrows with tight spacing)
XrayAuto.LADDER_SEED_MIN = 0.03      -- round 19: absolute noise floor; the EFFECTIVE seed floor is max(this, spacing/2) — item 38 E7

--- P2(a) formula v2 (§7, device round 2): rung spacing targets a pages-per-rung
--- band. The 10% baseline is narrowed on long books so a single rung never
--- extracts much more than LADDER_MAX_RUNG_PAGES (call SIZE bound — a 1500-page
--- book gets ~7% rungs, not 150-page deltas), widened on short books by the
--- min-pages floor (a novella must not burn a call on a 10-page slice). Spacing
--- is clamped to [LADDER_MIN_SPACING, LADDER_MAX_SPACING]: the floor bounds call
--- COUNT on monster books (size may exceed the ceiling there — the two bounds
--- can't both hold, and count wins past ~2000 pages), the cap keeps tiny books
--- at two rungs. Rounded to whole percents (the cost dialog displays it).
--- @param total_pages number|nil document page count
--- @return number spacing ratio (LADDER_MIN_SPACING..LADDER_MAX_SPACING)
function XrayAuto.ladderSpacingFor(total_pages)
  local pages = tonumber(total_pages)
  if not pages or pages <= 0 then return XrayAuto.LADDER_SPACING end
  local spacing = math.min(XrayAuto.LADDER_SPACING, XrayAuto.LADDER_MAX_RUNG_PAGES / pages)
  spacing = math.max(spacing, XrayAuto.LADDER_MIN_RUNG_PAGES / pages)
  spacing = math.floor(spacing * 100 + 0.5) / 100
  if spacing < XrayAuto.LADDER_MIN_SPACING then return XrayAuto.LADDER_MIN_SPACING end
  if spacing > XrayAuto.LADDER_MAX_SPACING then return XrayAuto.LADDER_MAX_SPACING end
  return spacing
end

--- P3 (§7): snap rung targets to chapter-end boundaries so versions read as
--- "up to the end of a chapter" instead of an arbitrary percent. Pure.
--- Boundaries above 1 - SNAP_WINDOW are ignored (a rung that close to the end
--- is the final rung's job) — which also guarantees the 1.0 rung survives the
--- ordering pass below. A target that lands within the update path's 1%
--- engagement threshold of its predecessor (or the base) is dropped: two rungs
--- collapsing onto one chapter build it once.
--- @param rungs table planLadderRungs output (ascending ratios, last = 1.0)
--- @param boundaries table|nil ascending { ratio, title } chapter ends; fewer than 3 = unusable TOC, no-op
--- @param base_progress number|nil the build base (0..1)
--- @param spacing number|nil the rung spacing (formula v2: narrow spacings shrink
--- the snap distance to 40% of a step so ±window never spans adjacent targets;
--- nil keeps the full LADDER_SNAP_WINDOW — the pre-v2 behavior)
--- @return table targets (ascending ratios), table labels (sparse, parallel: labels[i] = chapter title of targets[i])
function XrayAuto.snapLadderRungs(rungs, boundaries, base_progress, spacing)
  if type(boundaries) ~= "table" or #boundaries < 3 then
    return rungs, {}
  end
  local window = XrayAuto.LADDER_SNAP_WINDOW
  if tonumber(spacing) and spacing * 0.4 < window then
    window = spacing * 0.4
  end
  local targets, labels = {}, {}
  local prev = tonumber(base_progress) or 0
  for _idx, target in ipairs(rungs) do
    local snapped, label = target, nil
    if target < 1.0 - XrayAuto.LADDER_TOLERANCE then
      local best_d
      for _b, b in ipairs(boundaries) do
        local ratio = tonumber(b.ratio)
        if ratio and ratio <= 1.0 - XrayAuto.LADDER_SNAP_WINDOW then
          local d = math.abs(ratio - target)
          if d <= window and (not best_d or d < best_d) then
            best_d = d
            snapped = math.floor(ratio * 1000 + 0.5) / 1000
            label = b.title
          end
        end
      end
    end
    if snapped > prev + 0.01 then
      targets[#targets + 1] = snapped
      if label then labels[#targets] = label end
      prev = snapped
    end
  end
  return targets, labels
end

--- Even-grid normalization (device rounds 2026-08-05: a 12% grid produced
--- 96% + 100%, a 24% grid likewise 96% — terminal slivers a quarter of a step
--- wide). Adjust spacing to the nearest whole-number division of the goal span
--- so the last regular multiple lands ON the goal: spacing' = goal /
--- round(goal/spacing). Count stays within half a step of nominal (12% → 12.5%
--- x 8 instead of 12% x 8 + a 4% sliver; 24% → 25% x 4; a 45% novella grid →
--- 50% x 2 instead of 45/90/100). Pure.
--- @param spacing number|nil rung spacing 0..1 (nil = LADDER_SPACING)
--- @param goal number|nil build goal (nil/invalid = 1.0)
--- @return number normalized spacing
function XrayAuto.normalizedSpacing(spacing, goal)
  local s = tonumber(spacing)
  if not s or s <= 0 then s = XrayAuto.LADDER_SPACING end
  local g = tonumber(goal)
  if not g or g <= 0 or g > 1.0 then g = 1.0 end
  local n = math.floor(g / s + 0.5)
  if n < 1 then n = 1 end
  return g / n
end

--- Plan the rung targets for a build: multiples of `spacing` above
--- `base_progress`, plus a final 1.0. Pure; rounded to 3 decimals so float drift
--- never produces 0.30000000000000004-style targets. Spacing is even-grid
--- normalized against the goal (normalizedSpacing) so the final step is a full
--- step, never a sliver.
--- The first rung must sit at least HALF a step ahead of the base (maintainer
--- 2026-07-26: an X-Ray at 48% must not get a 50% rung — a near-boundary rung
--- spends a whole call on a near-duplicate; the base version itself covers that
--- neighborhood in the version set, staying live until promotion ring-archives
--- it). Half-spacing also always clears the update path's 1% engagement
--- threshold, and scales if spacing ever becomes a dial.
--- @param base_progress number|nil 0..1 (nil/0 = build from nothing)
--- @param spacing number|nil override (default LADDER_SPACING)
--- @return table Ascending array of target ratios (empty when base is ≥ ~99%)
function XrayAuto.planLadderRungs(base_progress, spacing, target_end)
  local base = tonumber(base_progress) or 0
  -- Round 16 (unified creation flow): optional target bounds the build — cover
  -- a huge section in prefix steps without paying for the rest of the book yet.
  -- nil/invalid = 1.0 (the pre-target behavior; resume later can extend).
  local goal = tonumber(target_end)
  if not goal or goal <= 0 or goal > 1.0 then goal = 1.0 end
  spacing = XrayAuto.normalizedSpacing(spacing, goal)
  -- Within 1% of the goal the update path wouldn't engage — nothing to build
  if base >= goal - 0.01 then return {} end
  local rungs = {}
  local n = math.floor((base + spacing / 2 - 1e-9) / spacing) + 1
  local target = math.floor(n * spacing * 1000 + 0.5) / 1000
  while target < goal - XrayAuto.LADDER_TOLERANCE do
    rungs[#rungs + 1] = target
    n = n + 1
    target = math.floor(n * spacing * 1000 + 0.5) / 1000
  end
  rungs[#rungs + 1] = goal
  return rungs
end

--- Round 19 (maintainer: "no openable X-Ray until the first checkpoint"): a
--- from-nothing build whose reader sits BELOW the first spacing rung gets a SEED
--- rung exactly at the reading position, so the very first finished checkpoint
--- is promotable and the reader has a live X-Ray right away. Pure.
--- Returns nil when a base exists (something is already live/promotable), when
--- the reader hasn't read HALF A STEP yet (item 38 E7: the seed is a call like
--- any rung, so the grid's half-step economics apply to it too — floor =
--- max(LADDER_SEED_MIN, spacing/2); a flat 3% floor let a 4% reader on a
--- 50%-spacing novella buy a two-page checkpoint right next to the intro, which
--- already serves that reader), when the reader sits AT or PAST the first
--- spacing rung (round 22, D1: the grid itself has a promotable point then — a
--- seed there would swallow every grid point below it into ONE unbounded
--- request), or when the position is within the goal's engagement threshold
--- (the goal rung IS the seed then). The seed deliberately never snaps to a
--- chapter boundary ahead of the reader — a seed past the position could not
--- promote.
--- @param base_progress number|nil build base 0..1 (nil/0 = from nothing)
--- @param position number|nil reading position 0..1
--- @param goal number|nil build target (nil = 1.0)
--- @param spacing number|nil rung spacing (nil = LADDER_SPACING) — floor and ceiling
--- @param force boolean|nil rebuild chains (2026-08-15): the swap at rung 1
--- replaces the live X-Ray, so the reader MUST get a promotable rung right
--- away — the half-step economics floor yields to the absolute minimum
--- (without this, a reader below step/2 lost their live artifact until the
--- chain reached the first spacing rung)
--- @return number|nil seed ratio (3 decimals)
function XrayAuto.seedForBuild(base_progress, position, goal, spacing, force)
  local base = tonumber(base_progress) or 0
  if base >= 0.01 then return nil end
  local pos = tonumber(position)
  -- The NORMALIZED step (the actual grid) — a reader between the nominal and
  -- normalized first rung must still get a seed, or D1's "grid has a
  -- promotable point" premise fails for them
  local step = XrayAuto.normalizedSpacing(spacing, goal)
  if not pos or pos < (force and XrayAuto.LADDER_SEED_MIN
      or math.max(XrayAuto.LADDER_SEED_MIN, step / 2)) then return nil end
  if pos >= step then return nil end
  local g = tonumber(goal)
  if not g or g <= 0 or g > 1.0 then g = 1.0 end
  if pos >= g - 0.01 then return nil end
  return math.floor(pos * 1000 + 0.5) / 1000
end

--- Full build plan incl. the seed: the tail is planned FROM the seed, so the
--- half-spacing rule naturally drops a spacing rung the seed already covers
--- (a seed at 12% with 15% spacing plans 30% next, not 15%). Pure.
--- @return table ascending rung targets (seed first when present), number|nil seed
function XrayAuto.planBuildRungs(base_progress, spacing, target_end, position, force_seed)
  local seed = XrayAuto.seedForBuild(base_progress, position, target_end, spacing, force_seed)
  local rungs = XrayAuto.planLadderRungs(seed or base_progress, spacing, target_end)
  if seed then table.insert(rungs, 1, seed) end
  return rungs, seed
end

--- Round 22 (T2): the auto scheduler's pure decision core — everything
--- _fireXrayAutoCheckpoints derives before planning the grid. Pure over its
--- inputs; the caller does the disk reads.
--- state = {
---   entry         = ActionCache.get(file, "xray") result (or nil),
---   ladder        = ActionCache.getXrayLadder(file) array,
---   base_progress = ActionCache.highestXrayLadderProgress(ladder),
---   position      = reading position 0..1 (nil = unknown),
---   goal          = raw per-book coverage goal (validated here),
---   is_json       = XrayParser.isJSON (or nil to skip the format check),
--- }
--- @return table {
---   base            highest usable build base (nil = from nothing),
---   has_intro       an intro exists (live or rung),
---   has_any         a NON-intro artifact exists (D1: intro-only books are
---                   still a first spend for the create guard and the ask),
---   goal            validated goal or nil (= whole book),
---   plan_intro      establishment should build the intro first,
---   build           true when the engine should build now,
---   lineage_blocked / reason ("no_position"|"goal_reached"|"ahead")
---                   set when it should not,
--- }
function XrayAuto.planAutoWork(state)
  local out = { base = tonumber(state.base_progress) }
  local entry = state.entry
  if entry and entry.result and not entry.intro then
    if entry.full_document or entry.source_mode == "ai_knowledge"
        or (state.is_json and not state.is_json(entry.result)) then
      -- Different lineage (complete-track / AI-knowledge / legacy text):
      -- automation never builds over or beside it
      if out.base == nil then
        out.lineage_blocked = true
        return out
      end
    else
      local p = tonumber(entry.progress_decimal)
      if p and (out.base == nil or p > out.base) then out.base = p end
    end
  end
  out.has_intro = false
  out.has_any = (entry and entry.result and not entry.intro) and true or false
  for _idx, r in ipairs(state.ladder or {}) do
    if r.intro then out.has_intro = true else out.has_any = true end
  end
  local goal = tonumber(state.goal)
  if goal and (goal <= 0.01 or goal >= 0.995) then goal = nil end
  out.goal = goal
  local pos = tonumber(state.position)
  if not pos then
    out.reason = "no_position"
    return out
  end
  if (out.base or 0) >= (goal or 1.0) - 0.01 then
    out.reason = "goal_reached"
    return out
  end
  -- One-ahead invariant: a built checkpoint (or live coverage) ahead of the
  -- reader means there is nothing to do yet. "Ahead" reaches BUILD_LAG behind
  -- the reader: the next build waits until the newest rung has installed and
  -- the reader moved a few pages past it.
  local ahead = false
  for _idx, r in ipairs(state.ladder or {}) do
    local p = tonumber(r.progress_decimal)
    if p and r.result and not r.intro and p + XrayAuto.BUILD_LAG > pos then
      ahead = true break
    end
  end
  if not ahead and entry and entry.result and not entry.intro then
    local p = tonumber(entry.progress_decimal)
    if p and p + XrayAuto.BUILD_LAG > pos then ahead = true end
  end
  if ahead then
    out.reason = "ahead"
    return out
  end
  out.plan_intro = out.base == nil and not out.has_intro
  out.build = true
  return out
end

--- Rungs that evidence a BUILD CHAIN (item 40): ladder/auto products incl. the
--- intro; legacy rungs predate producer stamping and were all chain-built, so
--- nil counts. Manual folds (slice 2) are timeline points, NOT chain evidence —
--- a lone manual update must never surface "Resume building checkpoints". Pure.
--- @param ladder table Rung array (any order)
--- @return number count
function XrayAuto.chainRungCount(ladder)
  local n = 0
  for _idx, rung in ipairs(ladder or {}) do
    if rung.producer ~= "manual" then n = n + 1 end
  end
  return n
end

--- Pick the rung to promote into the live cache: the highest rung at-or-below
--- the reading position (½% tolerance) that is AHEAD of the live entry. Rungs
--- ahead of the reader never qualify under the default TRACK posture (spoiler
--- by definition — same rule as nearestCheckpointIndex); full-document entries
--- never qualify. 50(f): under the FULL posture (spoiler protection off for
--- the book) pass opts.ahead_ok — the position ceiling drops and the pick is
--- simply the highest built rung ahead of the live entry.
--- @param ladder table Rung array (any order)
--- @param live_progress number|nil live cache progress 0..1
--- @param position number|nil reading position 0..1 (may be nil with ahead_ok)
--- @param opts table|nil { ahead_ok = true } → drop the position ceiling
--- @return table|nil rung entry
function XrayAuto.pickPromotableRung(ladder, live_progress, position, opts)
  local ahead_ok = (opts and opts.ahead_ok) or false
  if type(position) ~= "number" and not ahead_ok then return nil end
  local best, best_p
  for _idx, rung in ipairs(ladder or {}) do
    local p = tonumber(rung.progress_decimal)
    if p and not rung.full_document
        and (ahead_ok or p <= position + XrayAuto.PROMOTE_TOLERANCE)
        and p > (tonumber(live_progress) or 0) + XrayAuto.LADDER_TOLERANCE then
      if not best_p or p > best_p then
        best, best_p = rung, p
      end
    end
  end
  return best
end

--- Pick the ONE rung the identification peek may read (B269, 2026-08-25):
--- the LOWEST built rung that is past the live coverage AND whose coverage
--- reaches the reading position — the checkpoint covering the stretch the
--- reader is in right now. Never the newest: a ladder built to 100% used
--- to identify an early minor character from the 100% entry, where they
--- were already an alias of the revealed identity (issue #90). No position
--- = no peek; a rung not built yet = the name is simply unknown for now.
--- Shared by the card resolver, the marks index and the exact-route index
--- so marked == resolvable holds.
--- @param ladder table Rung array (any order)
--- @param live_progress number|nil live cache progress 0..1
--- @param position number|nil reading position 0..1
--- @return table|nil rung entry
function XrayAuto.pickAheadRung(ladder, live_progress, position)
  if type(position) ~= "number" then return nil end
  local live_p = tonumber(live_progress) or 0
  local best, best_p
  for _idx, rung in ipairs(ladder or {}) do
    local p = rung.full_document and 1.0 or tonumber(rung.progress_decimal)
    if p and rung.result and not rung.intro
        and p > live_p + XrayAuto.LADDER_TOLERANCE
        and p + XrayAuto.LADDER_TOLERANCE >= position then
      if not best_p or p < best_p then
        best, best_p = rung, p
      end
    end
  end
  return best
end

-- Build-chain session state (module-local, survives instance teardown like the
-- flight state — though a book close cancels the chain anyway). One build at a
-- time, plugin-wide.
local ladder_build = nil  -- { file, rungs = {targets}, idx, total, cancel_requested }

--- @return table|nil the active build state (nil when idle)
function XrayAuto.ladderBuild()
  return ladder_build
end

--- @param labels table|nil sparse array parallel to rungs (snapLadderRungs output):
--- labels[i] = chapter title for rungs[i], carried into each rung's cache entry
--- @param opts table|nil { intro = true } → an INTRODUCTORY step runs before
--- rung 1 (round 20): it reads the same opening slice as rung 1 but writes a
--- premise-only rung at progress 0, openable at any position. The display
--- total counts it; `idx` stays the RUNG index (the intro never consumes it),
--- `step` is the display step number. { silent = true } (round 21) → an auto
--- scheduler chain: routine progress/completion toasts are gated on the
--- xray_auto_notify opt-in (failures stay visible either way).
--- { rebuild = true } (deferred-rebuild fix 2026-08-14) → this chain REPLACES
--- the current X-Ray lineage, but touches NOTHING until its first rung
--- succeeds: the rung fire plans from scratch (ignoring the live artifact and
--- old rungs), and the rung WRITE performs the swap exactly once — archive
--- the outgoing live, clear the old ladder, then store (`rebuild_swapped`
--- flips there). A chain cancelled or failed before that leaves the book
--- exactly as it was. The old eager archive+clear at the confirm destroyed a
--- live X-Ray and an unarchived checkpoint on a build the user then DECLINED
--- (device 2026-08-14) — nothing may be destroyed before a run completes.
function XrayAuto.beginLadderBuild(file, rungs, labels, opts)
  ladder_build = { file = file, rungs = rungs, labels = labels, idx = 1,
    total = #rungs + ((opts and opts.intro) and 1 or 0),
    intro_pending = (opts and opts.intro) or nil,
    silent = (opts and opts.silent) or nil,
    rebuild = (opts and opts.rebuild) or nil,
    -- 2026-08-15: a commissioned one-shot installs its goal rung at completion
    -- regardless of the promotion posture (the user explicitly asked for that
    -- coverage) — the completion handler keys off this flag
    one_shot = (opts and opts.one_shot) or nil,
    step = 1 }
  -- A (re)start supersedes the last pause reason (item 45)
  if last_ladder_stop and last_ladder_stop.file == file then
    last_ladder_stop = nil
  end
end

--- The step the chain should fire next: { target, intro } or nil when done.
function XrayAuto.currentLadderStep()
  if not ladder_build then return nil end
  if ladder_build.intro_pending then
    return { target = ladder_build.rungs[1], intro = true }
  end
  local t = ladder_build.rungs[ladder_build.idx]
  if not t then return nil end
  return { target = t }
end

--- Mark the intro step done (or skipped); rung 1 fires next, idx unchanged.
function XrayAuto.completeIntro()
  if ladder_build and ladder_build.intro_pending then
    ladder_build.intro_pending = nil
    ladder_build.step = (ladder_build.step or 1) + 1
  end
end

--- Advance to the next rung. Returns the next target ratio, or nil when done.
function XrayAuto.advanceLadderBuild()
  if not ladder_build then return nil end
  ladder_build.idx = ladder_build.idx + 1
  ladder_build.step = (ladder_build.step or ladder_build.idx) + 1
  return ladder_build.rungs[ladder_build.idx]
end

function XrayAuto.endLadderBuild()
  ladder_build = nil
end

--- Ask the chain to stop after the current rung completes (a rung mid-network
--- additionally gets cancelInFlight from the caller).
function XrayAuto.requestLadderCancel()
  if ladder_build then ladder_build.cancel_requested = true end
end

-- Round 22 (D3): an explicit user cancel must mean something distinct from
-- "chain ended" — without this, the next page turn re-plans the very chain the
-- user just cancelled (the cooldown was stamped at SCHEDULE time and has often
-- already elapsed). Session-scoped per-file suppression: unattended auto fires
-- skip suppressed books; any explicit engine start (follow pick, build confirm,
-- offer accept) or a book close clears it. Cross-instance module state, same
-- rationale as the flight state above.
local auto_suppressed = {}

function XrayAuto.suppressAuto(file)
  if file then auto_suppressed[file] = true end
end

function XrayAuto.clearAutoSuppression(file)
  if file then auto_suppressed[file] = nil end
end

function XrayAuto.isAutoSuppressed(file)
  return file ~= nil and auto_suppressed[file] == true
end

return XrayAuto
