import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {test} from "node:test"

import {DEFAULT_AXIS_TEMPLATES, formatAxisYear} from "../lib/time_format.js"

// Reads the SAME fixture file `test/amanogawa/atlas/time_scale/format_test.exs`
// reads (no copy).
const fixturePath = fileURLToPath(
  new URL("../../../test/support/fixtures/time_scale/labels.json", import.meta.url)
)
const fixture = JSON.parse(readFileSync(fixturePath, "utf8"))

test("happy path: every fixture case matches its expected label", () => {
  for (const testCase of fixture.cases) {
    assert.equal(formatAxisYear(testCase.year, testCase.step), testCase.expected)
  }
})

test("happy path: ka BP regime rounds to the nearest thousand", () => {
  assert.equal(formatAxisYear(-98050, 1000), "100 ka BP")
  assert.equal(formatAxisYear(-10000, 1000), "12 ka BP")
})

test("happy path: century regime handles both eras", () => {
  assert.equal(formatAxisYear(-750, 100), "VIIIe s. av. J.-C.")
  assert.equal(formatAxisYear(1100, 100), "XIIe s.")
})

test("happy path: plain year regime handles both eras", () => {
  assert.equal(formatAxisYear(1969, 1), "1969")
  assert.equal(formatAxisYear(-489, 1), "490 av. J.-C.")
})

test("edge case: year 0 (1 av. J.-C.) is not rendered as a bare 0", () => {
  assert.equal(formatAxisYear(0, 1), "1 av. J.-C.")
})

test("edge case: the regime is picked from step, not an implicit zoom level", () => {
  assert.equal(formatAxisYear(1100, 1), "1100")
  assert.equal(formatAxisYear(1100, 100), "XIIe s.")
})

test("happy path: caller-provided templates localize every regime (F04 quality finding m6)", () => {
  const templates = {kaBp: "%{ka} ka BP", century: "%{century}th c.", bce: "%{text} BCE"}

  assert.equal(formatAxisYear(-98050, 1000, templates), "100 ka BP")
  assert.equal(formatAxisYear(-750, 100, templates), "VIIIth c. BCE")
  assert.equal(formatAxisYear(1100, 100, templates), "XIIth c.")
  assert.equal(formatAxisYear(-489, 1, templates), "490 BCE")
  assert.equal(formatAxisYear(1969, 1, templates), "1969")
})

test("edge case: the default templates are the French fixture language", () => {
  assert.deepEqual(DEFAULT_AXIS_TEMPLATES, {
    kaBp: "%{ka} ka BP",
    century: "%{century}e s.",
    bce: "%{text} av. J.-C."
  })
})
