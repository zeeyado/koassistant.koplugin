--[[--
Background X-Ray auto-update: trigger gates + cross-instance session state
(docs/xray_background_plan.md).

Gate logic is pure (quiz_chapters precedent — no KOReader deps, unit-testable):
`shouldFire(state, progress_decimal, pageno, now)` answers from its arguments only.
The module additionally holds file-local session state that must survive ReaderUI
plugin-instance teardown on book switch (`last_attempt`, the in-flight flag, the
subprocess cancel handle, and the session failure/success trace): per-instance
`self._*` state would reset the rate limit on every book hop and orphan the
in-flight flag. main.lua owns all event wiring and disk reads.
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
XrayAuto.WATCHDOG_S = 120        -- absolute cancel; don't rely on the child's socket timeout

-- Cross-instance session state (file-local module state, NOT self._*)
local last_attempt = nil   -- stamped at SCHEDULE time, not fire time
local in_flight = false
local cancel_fn = nil
local last_failure = nil   -- { file = path, message = string }
local session_updates = 0
local cancelled = false    -- set when an actual flight was cancelled (close/watchdog)
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

--- Pure trigger gate. All checks answerable from arguments; disk truth (fresh cache
--- read, WiFi, document type) is the caller's job at fire time. Dial fields on state
--- (min_gap/max_gap/cooldown_s, from dialsFromFeatures) override the module defaults.
--- @param state table { auto_update, eligible, cached_progress, prev_page, min_gap, max_gap, cooldown_s } (may be stale)
--- @param progress_decimal number current position 0..1 (cheap approximation is fine)
--- @param pageno number current page (jump guard)
--- @param now number os.time()
--- @return table { fire = boolean, reason = string }
function XrayAuto.shouldFire(state, progress_decimal, pageno, now)
  if not state or state.auto_update ~= true then
    return { fire = false, reason = "not_opted_in" }
  end
  if state.eligible ~= true then
    return { fire = false, reason = "not_eligible" }
  end
  if type(progress_decimal) ~= "number" or type(state.cached_progress) ~= "number" then
    return { fire = false, reason = "no_progress" }
  end
  local delta = progress_decimal - state.cached_progress
  if delta <= (state.min_gap or XrayAuto.THRESHOLD) then
    return { fire = false, reason = "below_threshold" }
  end
  if delta > (state.max_gap or XrayAuto.MAX_DELTA) then
    return { fire = false, reason = "above_cap" }
  end
  -- Jump guard: no prev_page (first turn after open/refresh) or a big hop = not
  -- sequential reading; the page was still tracked by the caller.
  if not state.prev_page or math.abs((pageno or 0) - state.prev_page) > XrayAuto.JUMP_GUARD_PAGES then
    return { fire = false, reason = "page_jump" }
  end
  if last_attempt and now and (now - last_attempt) < (state.cooldown_s or XrayAuto.RATE_LIMIT_S) then
    return { fire = false, reason = "rate_limited" }
  end
  if in_flight then
    return { fire = false, reason = "in_flight" }
  end
  return { fire = true, reason = "ok" }
end

--- Stamp the rate limit at SCHEDULE time (several page turns can pass the gates
--- inside the deferral window; only the first may schedule).
function XrayAuto.markScheduled(now)
  last_attempt = now
end

function XrayAuto.beginFlight()
  in_flight = true
end

function XrayAuto.endFlight()
  in_flight = false
  cancel_fn = nil
end

function XrayAuto.isInFlight()
  return in_flight
end

--- Store the cancel handle returned by the silent request path (gpt_query
--- `config._register_cancel`). Called from inside the request machinery.
function XrayAuto.registerCancel(fn)
  cancel_fn = fn
end

--- Cancel a background request in flight (document close, watchdog). Safe no-op
--- when idle. The completion guard makes a straggler write impossible either way.
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

return XrayAuto
