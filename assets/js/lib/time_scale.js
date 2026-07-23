// Symlog time scale shared by the timeline (issue #020) and the map:
// linear near the present, logarithmic toward the deep past, with a pivot
// around the Neolithic (`.claude/rules/geo-temporal.md`, ADR 0005).
//
// This is the JS mirror of `Amanogawa.Atlas.TimeScale`
// (`lib/amanogawa/atlas/time_scale.ex`), which is the authoritative
// moduledoc for the formulas below: same formulas, same default
// configuration, same clamping behavior, same BP tick convention. If the
// two implementations ever diverge, the histogram (#020, SQL `width_bucket`
// on this scale's position) desynchronizes from the axis this module
// positions client-side. Both sides are tested against the single shared
// fixture `test/support/fixtures/time_scale/anchors.json`
// (`assets/js/test/time_scale.test.js` here, ExUnit on the Elixir side),
// tolerance 1.0e-9.
//
// Formulas (see the Elixir moduledoc for the full derivation):
//
//   t(year) = ln(1 + (max_year - year) / pivot)
//   position(year) = 1 - t(year) / t(min_year)
//   year(position) = max_year - pivot * (exp((1 - position) * t(min_year)) - 1)
//
// No dependency, no DOM: pure and testable under plain Node (`node:test`),
// exactly like `assets/js/map/*.js`. d3 only enters at render time (#020).

const DEFAULT_MIN_YEAR = -300000
const DEFAULT_MAX_YEAR = 2100
const DEFAULT_PIVOT = 10000

// Radiocarbon "before present" epoch: BP = BP_EPOCH - year.
const BP_EPOCH = 1950

// Fixed display convention (issue #019/#020): below this astronomical year,
// ticks and axis labels switch to the BP regime. Independent of a custom
// scale's pivot, which is a formula parameter, not a labeling convention.
export const BP_THRESHOLD_YEAR = -10000

const DEFAULT_TICK_COUNT = 6

// Rounds to the nearest integer, ties away from zero: matches Elixir's
// `Kernel.round/1` exactly (JS's native `Math.round` instead rounds ties
// toward +Infinity, which would disagree with the Elixir side on exact
// half-integer inputs). Kept private: every rounding point in this module
// goes through it so the two implementations never drift on a tie.
function roundHalfAwayFromZero(value) {
  return value >= 0 ? Math.floor(value + 0.5) : Math.ceil(value - 0.5)
}

function clamp(value, min, max) {
  if (value < min) return min
  if (value > max) return max
  return value
}

function order(from, to) {
  return from <= to ? [from, to] : [to, from]
}

// Chooses a "round" step (1, 2, 5, or 10 times a power of ten) so that
// `range / step` is close to `targetCount`, floored at 1 (years are
// integers, sub-year ticks make no sense on this scale).
function niceStep(range, targetCount) {
  const count = Math.max(targetCount, 1)
  const rawStep = range / count

  if (rawStep <= 1) return 1

  const magnitude = Math.pow(10, Math.floor(Math.log10(rawStep)))
  const residual = rawStep / magnitude

  let nice
  if (residual <= 1) nice = 1
  else if (residual <= 2) nice = 2
  else if (residual <= 5) nice = 5
  else nice = 10

  return Math.max(roundHalfAwayFromZero(nice * magnitude), 1)
}

// Smallest multiple of `step` greater than or equal to `value`.
function ceilToStep(value, step) {
  return roundHalfAwayFromZero(Math.ceil(value / step) * step)
}

// BP grows as the (astronomical, negative) year shrinks: `bpHigh` (oldest,
// from `from`) down to `bpLow` (closest to present, from `to`). Round BP
// values are generated ascending from `bpLow` to `bpHigh`, then mapped back
// to years and sorted ascending, so the final tick order is always
// chronological regardless of the BP/year inversion.
function deepTicks(from, to, count) {
  const bpHigh = BP_EPOCH - from
  const bpLow = BP_EPOCH - to
  const step = niceStep(bpHigh - bpLow, count)

  const years = []
  for (let bp = ceilToStep(bpLow, step); bp <= bpHigh; bp += step) {
    years.push(BP_EPOCH - bp)
  }

  return years.sort((a, b) => a - b)
}

function recentTicks(from, to, count) {
  const step = niceStep(to - from, count)
  const years = []

  for (let year = ceilToStep(from, step); year <= to; year += step) {
    years.push(year)
  }

  return years
}

function splitTicks(from, to, count) {
  const deepSpan = BP_THRESHOLD_YEAR - from
  const recentSpan = to - BP_THRESHOLD_YEAR
  const totalSpan = deepSpan + recentSpan

  const deepCount = Math.max(roundHalfAwayFromZero((count * deepSpan) / totalSpan), 1)
  const recentCount = Math.max(count - deepCount, 1)

  const deep = deepTicks(from, BP_THRESHOLD_YEAR, deepCount)
  const recent = recentTicks(BP_THRESHOLD_YEAR, to, recentCount)

  return Array.from(new Set([...deep, ...recent])).sort((a, b) => a - b)
}

// Builds a validated time scale. `config` may override `minYear`,
// `maxYear`, `pivot`; every field defaults to the documented default
// domain (mirrors `Amanogawa.Atlas.TimeScale.new/1`'s defaults exactly).
//
// Throws a plain `Error` when `minYear >= maxYear` or `pivot <= 0` (the JS
// mirror of the Elixir side's `{:error, reason}`, documented here since JS
// has no tagged-tuple convention to lean on).
export function createTimeScale(config = {}) {
  const minYear = config.minYear ?? DEFAULT_MIN_YEAR
  const maxYear = config.maxYear ?? DEFAULT_MAX_YEAR
  const pivot = config.pivot ?? DEFAULT_PIVOT

  if (!(minYear < maxYear)) throw new Error("minYear must be less than maxYear")
  if (!(pivot > 0)) throw new Error("pivot must be a positive integer")

  function t(year) {
    return Math.log1p((maxYear - year) / pivot)
  }

  const tMin = t(minYear)

  // Maps `year` to its normalized position in [0.0, 1.0]. Out-of-domain
  // years are clamped, never throw.
  function position(year) {
    const clampedYear = clamp(year, minYear, maxYear)
    return 1 - t(clampedYear) / tMin
  }

  // Maps `position` (normalized [0.0, 1.0]) back to an astronomical year,
  // rounded to the nearest integer year. Out-of-range positions are
  // clamped first, never throw.
  function year(position) {
    const clampedPosition = clamp(position, 0.0, 1.0)
    const rawYear = maxYear - pivot * Math.expm1((1 - clampedPosition) * tMin)

    return clamp(roundHalfAwayFromZero(rawYear), minYear, maxYear)
  }

  // Adaptive tick years for the sub-window `[from, to]` (order-independent,
  // swapped automatically), targeting `count` graduations. See
  // `Amanogawa.Atlas.TimeScale.ticks/3` for the full contract: strictly
  // increasing, duplicate-free, contained in the (clamped) window.
  function ticks(from, to, count = DEFAULT_TICK_COUNT) {
    const [orderedFrom, orderedTo] = order(from, to)
    const clampedFrom = clamp(orderedFrom, minYear, maxYear)
    const clampedTo = clamp(orderedTo, minYear, maxYear)
    const targetCount = Math.max(count, 1)

    if (clampedTo <= BP_THRESHOLD_YEAR) return deepTicks(clampedFrom, clampedTo, targetCount)
    if (clampedFrom >= BP_THRESHOLD_YEAR) return recentTicks(clampedFrom, clampedTo, targetCount)
    return splitTicks(clampedFrom, clampedTo, targetCount)
  }

  return {minYear, maxYear, pivot, position, year, ticks}
}
