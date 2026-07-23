import assert from "node:assert/strict"
import {test} from "node:test"

import {clampWindow, resizeEdge, translateWindow} from "../lib/time_window.js"

const DOMAIN = {minYear: -300000, maxYear: 2100}
const MIN_WIDTH = 1

test("happy path: resizeEdge moves the from bound, the to bound stays fixed", () => {
  const window = {from: -500, to: 500}
  const result = resizeEdge(window, "from", -200, DOMAIN, MIN_WIDTH)

  assert.deepEqual(result, {from: -200, to: 500})
})

test("happy path: resizeEdge moves the to bound, the from bound stays fixed", () => {
  const window = {from: -500, to: 500}
  const result = resizeEdge(window, "to", 800, DOMAIN, MIN_WIDTH)

  assert.deepEqual(result, {from: -500, to: 800})
})

test("happy path: translateWindow preserves the window width", () => {
  const window = {from: -500, to: 500}
  const result = translateWindow(window, 100, DOMAIN)

  assert.deepEqual(result, {from: -400, to: 600})
  assert.equal(result.to - result.from, window.to - window.from)
})

test("edge case: translating against the left edge of the domain stops flush, width preserved", () => {
  const window = {from: DOMAIN.minYear + 100, to: DOMAIN.minYear + 600}
  const result = translateWindow(window, -1000, DOMAIN)

  assert.deepEqual(result, {from: DOMAIN.minYear, to: DOMAIN.minYear + 500})
})

test("edge case: translating against the right edge of the domain stops flush, width preserved", () => {
  const window = {from: DOMAIN.maxYear - 600, to: DOMAIN.maxYear - 100}
  const result = translateWindow(window, 1000, DOMAIN)

  assert.deepEqual(result, {from: DOMAIN.maxYear - 500, to: DOMAIN.maxYear})
})

test("edge case: resizing the from bound past to - minWidth stops there, never crosses", () => {
  const window = {from: -500, to: 500}
  const result = resizeEdge(window, "from", 499, DOMAIN, MIN_WIDTH)

  assert.deepEqual(result, {from: 499, to: 500})
  assert.ok(result.to - result.from >= MIN_WIDTH)
})

test("edge case: resizing the to bound past from + minWidth stops there, never crosses", () => {
  const window = {from: -500, to: 500}
  const result = resizeEdge(window, "to", -501, DOMAIN, MIN_WIDTH)

  assert.deepEqual(result, {from: -500, to: -499})
  assert.ok(result.to - result.from >= MIN_WIDTH)
})

test("edge case: resizing past the domain bound clamps to the domain edge", () => {
  const window = {from: -500, to: 500}

  assert.deepEqual(resizeEdge(window, "from", -999999, DOMAIN, MIN_WIDTH), {
    from: DOMAIN.minYear,
    to: 500
  })
  assert.deepEqual(resizeEdge(window, "to", 999999, DOMAIN, MIN_WIDTH), {
    from: -500,
    to: DOMAIN.maxYear
  })
})

test("limit case: a window equal to the full domain is a valid resize target", () => {
  const window = {from: -1000, to: 1000}

  const grown = resizeEdge(window, "from", DOMAIN.minYear, DOMAIN, MIN_WIDTH)
  assert.deepEqual(grown, {from: DOMAIN.minYear, to: 1000})

  const grownFurther = resizeEdge(grown, "to", DOMAIN.maxYear, DOMAIN, MIN_WIDTH)
  assert.deepEqual(grownFurther, {from: DOMAIN.minYear, to: DOMAIN.maxYear})
})

test("limit case: a window at exactly minWidth is stable under a no-op resize", () => {
  const window = {from: 0, to: MIN_WIDTH}
  const result = resizeEdge(window, "from", 0, DOMAIN, MIN_WIDTH)

  assert.deepEqual(result, window)
})

test("clampWindow: a window already inside the domain is unchanged", () => {
  assert.deepEqual(clampWindow({from: -500, to: 500}, DOMAIN, MIN_WIDTH), {from: -500, to: 500})
})

test("clampWindow: an inverted window is reordered before clamping", () => {
  assert.deepEqual(clampWindow({from: 500, to: -500}, DOMAIN, MIN_WIDTH), {from: -500, to: 500})
})

test("clampWindow: a window far outside the domain clamps to the domain bounds", () => {
  const result = clampWindow({from: -13_800_000_000, to: 2_026}, DOMAIN, MIN_WIDTH)

  assert.deepEqual(result, {from: DOMAIN.minYear, to: 2_026})
})

test("clampWindow: a degenerate window (from === to) is widened to minWidth", () => {
  const result = clampWindow({from: 1000, to: 1000}, DOMAIN, MIN_WIDTH)

  assert.equal(result.to - result.from, MIN_WIDTH)
})

// Property (invariant de fenêtre): for any sequence of resize/translate
// gestures with arbitrary deltas, the window invariants always hold:
// domain.minYear <= from < to <= domain.maxYear and to - from >= minWidth.
// A small hand-rolled PRNG stands in for StreamData (JS side, per the
// issue's own note): deterministic (fixed seed) so a failure is
// reproducible without needing to print the seed.
function mulberry32(seed) {
  let state = seed
  return () => {
    state |= 0
    state = (state + 0x6d2b79f5) | 0
    let t = Math.imul(state ^ (state >>> 15), 1 | state)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function assertWindowInvariants(window, domain, minWidth, context) {
  assert.ok(window.from >= domain.minYear, `${context}: from >= domain.minYear`)
  assert.ok(window.to <= domain.maxYear, `${context}: to <= domain.maxYear`)
  assert.ok(window.from < window.to, `${context}: from < to`)
  assert.ok(window.to - window.from >= minWidth, `${context}: to - from >= minWidth`)
}

test("property: window invariants hold across 200 random gesture sequences", () => {
  const random = mulberry32(42)

  for (let sequence = 0; sequence < 200; sequence += 1) {
    let window = {from: -1000, to: 1000}
    assertWindowInvariants(window, DOMAIN, MIN_WIDTH, `sequence ${sequence}, initial`)

    const stepCount = Math.floor(random() * 20)

    for (let step = 0; step < stepCount; step += 1) {
      const delta = Math.floor((random() - 0.5) * 200000)

      if (random() < 0.5) {
        const edge = random() < 0.5 ? "from" : "to"
        const proposedYear = window[edge] + delta
        window = resizeEdge(window, edge, proposedYear, DOMAIN, MIN_WIDTH)
      } else {
        window = translateWindow(window, delta, DOMAIN)
      }

      assertWindowInvariants(window, DOMAIN, MIN_WIDTH, `sequence ${sequence}, step ${step}`)
    }
  }
})
