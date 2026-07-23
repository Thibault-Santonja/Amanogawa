import assert from "node:assert/strict"
import {test} from "node:test"

import {histogramBucketCount, initialTimeWindow, readDomain} from "../hooks/timeline.js"

const CURRENT_YEAR = new Date().getUTCFullYear()

test("readDomain: parses data-domain-min/data-domain-max (F04 decision D1)", () => {
  const domain = readDomain({domainMin: "-300000", domainMax: "2026"})

  assert.deepEqual(domain, {minYear: -300000, maxYear: 2026})
})

test("readDomain: missing attributes fall back to the shared scale defaults", () => {
  const domain = readDomain({})

  assert.deepEqual(domain, {minYear: -300000, maxYear: CURRENT_YEAR})
})

test("readDomain: malformed attributes fall back, never NaN", () => {
  const domain = readDomain({domainMin: "abc", domainMax: ""})

  assert.deepEqual(domain, {minYear: -300000, maxYear: CURRENT_YEAR})
})

const DOMAIN = {minYear: -300000, maxYear: CURRENT_YEAR}

test("initialTimeWindow: absent data-from/data-to yield the full domain", () => {
  const window = initialTimeWindow({}, DOMAIN)

  assert.deepEqual(window, {from: DOMAIN.minYear, to: DOMAIN.maxYear})
})

test("initialTimeWindow: an in-domain window passes through unchanged", () => {
  const window = initialTimeWindow({from: "1789", to: "1815"}, DOMAIN)

  assert.deepEqual(window, {from: 1789, to: 1815})
})

test("initialTimeWindow: an out-of-domain window is clamped at mount (F04 correction M1)", () => {
  // A stale astronomical-domain URL (pre-D1 bookmarks) must clamp to the
  // strip's domain instead of producing an out-of-bounds histogram fetch.
  const window = initialTimeWindow({from: "-13800000000", to: String(CURRENT_YEAR + 100)}, DOMAIN)

  assert.deepEqual(window, {from: DOMAIN.minYear, to: DOMAIN.maxYear})
})

test("initialTimeWindow: an inverted window is reordered, a degenerate one widened", () => {
  assert.deepEqual(initialTimeWindow({from: "500", to: "-500"}, DOMAIN), {from: -500, to: 500})

  const degenerate = initialTimeWindow({from: "1000", to: "1000"}, DOMAIN)
  assert.ok(degenerate.to - degenerate.from >= 1)
})

test("histogramBucketCount: adapts to width, quantized in steps of 20, bounded by the server cap", () => {
  // Quantized so only a significant resize changes the count (and thus
  // triggers a refetch), per F04 decision D2.
  assert.equal(histogramBucketCount(0), 20)
  assert.equal(histogramBucketCount(400), 40)
  assert.equal(histogramBucketCount(410), 40)
  assert.equal(histogramBucketCount(1232), 120)
  assert.equal(histogramBucketCount(10000), 200)
})

test("histogramBucketCount: never exceeds the server's buckets cap (200)", () => {
  for (const width of [0, 500, 2000, 100000]) {
    const buckets = histogramBucketCount(width)
    assert.ok(buckets >= 1 && buckets <= 200, `width=${width} -> ${buckets}`)
  }
})
