// Pure constraint logic for the interactive time window (issue #021):
// resizing one edge, translating the whole window, and clamping a raw
// window to a domain. No DOM, no d3, no MapLibre: `assets/js/hooks/
// timeline.js` owns the pixel <-> year conversion (through `time_scale.js`)
// and Pointer Events wiring, this module only owns "given a proposed year,
// what is the new, valid window" so the constraint rules are testable
// under plain `node:test`, independent of a browser.
//
// The domain here is `Amanogawa.Atlas.TimeScale`'s own `[minYear, maxYear]`
// (the symlog scale's rendering domain, e.g. the default `-300000..2100`),
// not the wider astronomical domain `Amanogawa.HistoricalDate` accepts
// (`-13_800_000_000..current year`): a window edge can never be dragged to
// a year the scale cannot position on the strip in the first place. The
// server-side validation of a client-pushed window
// (`AmanogawaWeb.Params.ExploreParams.valid_window?/2`) deliberately keeps
// the wider `HistoricalDate` domain, since it also validates windows that
// never went through a drag (a pasted URL, for instance): the two domains
// serve different purposes and are not meant to match.

function clamp(value, min, max) {
  if (value < min) return min
  if (value > max) return max
  return value
}

// Clamps a raw `{from, to}` window into `domain` (`{minYear, maxYear}`)
// and enforces `minWidth`: `to` is pushed out first if the pair is
// inverted or narrower than `minWidth`, then both bounds are clamped to
// the domain, with the width preserved by pulling the far bound inward
// when clamping the near one would otherwise cross it.
//
// Not used by the drag gesture itself (`resizeEdge`/`translateWindow`
// below already keep every intermediate state valid by construction); it
// exists for the one caller that receives a window from outside this
// module's own invariants, `TimelineHook`'s initial `data-from`/`data-to`
// read from the DOM.
export function clampWindow({from, to}, domain, minWidth) {
  const orderedFrom = Math.min(from, to)
  const orderedTo = Math.max(from, to, orderedFrom + minWidth)

  const clampedTo = clamp(orderedTo, domain.minYear + minWidth, domain.maxYear)
  const clampedFrom = clamp(orderedFrom, domain.minYear, clampedTo - minWidth)

  return {from: clampedFrom, to: clampedTo}
}

// Resizes a single edge of `window` (`"from"` or `"to"`) to `proposedYear`:
// the opposite bound never moves, the moved bound clamps to the domain and
// stops `minWidth` short of the opposite bound rather than crossing it.
export function resizeEdge(window, edge, proposedYear, domain, minWidth) {
  if (edge === "from") {
    const from = clamp(proposedYear, domain.minYear, window.to - minWidth)
    return {from, to: window.to}
  }

  const to = clamp(proposedYear, window.from + minWidth, domain.maxYear)
  return {from: window.from, to}
}

// Translates the whole `window` by `deltaYears`, preserving its width
// exactly: a translation that would push either bound past the domain
// stops flush at that edge (the window never silently narrows to fit).
export function translateWindow(window, deltaYears, domain) {
  const width = window.to - window.from
  const proposedFrom = window.from + deltaYears
  const from = clamp(proposedFrom, domain.minYear, domain.maxYear - width)

  return {from, to: from + width}
}
