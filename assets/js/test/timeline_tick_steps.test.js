import assert from "node:assert/strict"
import {test} from "node:test"

import {tickSteps} from "../hooks/timeline.js"

test("happy path: a uniform-step tick set reports that step for every tick", () => {
  const ticks = [1700, 1750, 1800, 1850]

  assert.deepEqual(tickSteps(ticks), [50, 50, 50, 50])
})

test("edge case: a tick set straddling a regime change reports the local step, not a global one", () => {
  // A window crossing the BP threshold merges two regimes
  // (`Amanogawa.Atlas.TimeScale.ticks/3`): coarse BP-derived ticks on one
  // side, finer calendar-year ticks on the other.
  const ticks = [-15000, -13000, -11000, -9000, -7000]

  assert.deepEqual(tickSteps(ticks), [2000, 2000, 2000, 2000, 2000])
})

test("edge case: a single-tick set falls back to a step of 1", () => {
  assert.deepEqual(tickSteps([1969]), [1])
})

test("edge case: an empty tick set returns an empty step list", () => {
  assert.deepEqual(tickSteps([]), [])
})

test("edge case: the first tick's step is measured against the second, not the previous", () => {
  const ticks = [1900, 1950, 2000]

  assert.deepEqual(tickSteps(ticks), [50, 50, 50])
})
