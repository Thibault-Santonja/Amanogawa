import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {test} from "node:test"

import {BP_THRESHOLD_YEAR, createTimeScale} from "../lib/time_scale.js"

// Reads the SAME fixture file `test/amanogawa/atlas/time_scale_test.exs`
// reads (no copy): the cross-language cohesion this issue exists to
// guarantee.
const fixturePath = fileURLToPath(
  new URL("../../../test/support/fixtures/time_scale/anchors.json", import.meta.url)
)
const fixture = JSON.parse(readFileSync(fixturePath, "utf8"))

function defaultScale() {
  return createTimeScale({
    minYear: fixture.config.min_year,
    maxYear: fixture.config.max_year,
    pivot: fixture.config.pivot
  })
}

test("happy path: every fixture anchor matches within the fixture's tolerance", () => {
  const scale = defaultScale()

  for (const anchor of fixture.anchors) {
    const actual = scale.position(anchor.year)
    const diff = Math.abs(actual - anchor.position)

    assert.ok(
      diff <= fixture.tolerance,
      `position(${anchor.year}) = ${actual}, expected ${anchor.position} (diff ${diff})`
    )
  }
})

test("happy path: the fixture contains every documented mandatory anchor", () => {
  const years = new Set(fixture.anchors.map(anchor => anchor.year))
  const mandatory = [-300000, -100000, -10000, -490, 0, 1000, 1789, 2000, 2100]

  for (const year of mandatory) {
    assert.ok(years.has(year), `missing mandatory anchor year ${year}`)
  }
})

test("limit case: position(minYear) is exactly 0.0 and position(maxYear) is exactly 1.0", () => {
  const scale = defaultScale()

  assert.equal(scale.position(scale.minYear), 0.0)
  assert.equal(scale.position(scale.maxYear), 1.0)
})

test("limit case: out-of-domain years are clamped, never throw", () => {
  const scale = defaultScale()

  assert.equal(scale.position(-1_000_000), 0.0)
  assert.equal(scale.position(1_000_000), 1.0)
})

test("limit case: year(0.0) is minYear and year(1.0) is maxYear", () => {
  const scale = defaultScale()

  assert.equal(scale.year(0.0), scale.minYear)
  assert.equal(scale.year(1.0), scale.maxYear)
})

test("limit case: out-of-range positions are clamped, never throw", () => {
  const scale = defaultScale()

  assert.equal(scale.year(-1.0), scale.minYear)
  assert.equal(scale.year(2.0), scale.maxYear)
})

test("error case: createTimeScale rejects minYear >= maxYear", () => {
  assert.throws(() => createTimeScale({minYear: 100, maxYear: 100}), /minYear must be less than maxYear/)
  assert.throws(() => createTimeScale({minYear: 200, maxYear: 100}), /minYear must be less than maxYear/)
})

test("error case: createTimeScale rejects a non-positive pivot", () => {
  assert.throws(() => createTimeScale({pivot: 0}), /pivot must be a positive integer/)
  assert.throws(() => createTimeScale({pivot: -1}), /pivot must be a positive integer/)
})

test("happy path: ticks on a recent window returns round, increasing years within the window", () => {
  const scale = defaultScale()
  const ticks = scale.ticks(1700, 2000, 6)

  assert.deepEqual(ticks, [...ticks].sort((a, b) => a - b))
  assert.equal(new Set(ticks).size, ticks.length)
  assert.ok(ticks.every(year => year >= 1700 && year <= 2000))
  assert.ok(ticks.length >= 2)
})

test("edge case: ticks across the BP threshold are coherent on both sides", () => {
  const scale = defaultScale()
  const ticks = scale.ticks(-15000, -5000, 6)

  assert.deepEqual(ticks, [...ticks].sort((a, b) => a - b))
  assert.equal(new Set(ticks).size, ticks.length)
  assert.ok(ticks.every(year => year >= -15000 && year <= -5000))
  assert.ok(ticks.some(year => year <= BP_THRESHOLD_YEAR))
  assert.ok(ticks.some(year => year > BP_THRESHOLD_YEAR))
})

test("edge case: a very narrow window does not duplicate ticks", () => {
  const scale = defaultScale()
  const ticks = scale.ticks(1969, 1970, 6)

  assert.equal(new Set(ticks).size, ticks.length)
  assert.ok(ticks.every(year => year >= 1969 && year <= 1970))
})

test("edge case: a degenerate window (from === to) returns at most one tick", () => {
  const scale = defaultScale()

  assert.deepEqual(scale.ticks(1969, 1969, 6), [1969])
})

test("edge case: from/to are swapped automatically when given in the wrong order", () => {
  const scale = defaultScale()

  assert.deepEqual(scale.ticks(2000, 1700, 6), scale.ticks(1700, 2000, 6))
})

test("property: round-trip year(position(year)) stays within 1 year for a sample of the domain", () => {
  const scale = defaultScale()
  const sample = [
    scale.minYear,
    -250000,
    -123456,
    -10000,
    -490,
    0,
    1000,
    1789,
    2000,
    scale.maxYear
  ]

  for (const year of sample) {
    const roundTripped = scale.year(scale.position(year))
    assert.ok(Math.abs(roundTripped - year) <= 1, `year=${year}, roundTripped=${roundTripped}`)
  }
})
