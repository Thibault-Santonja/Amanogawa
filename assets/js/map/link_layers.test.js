import assert from "node:assert/strict"
import {test} from "node:test"

import {
  HIDDEN_OPACITY,
  LINK_TYPES,
  LINKS_LAYER_ID,
  LINKS_SOURCE_ID,
  emptyFeatureCollection,
  linksLineLayer,
  linksSource
} from "./link_layers.js"

const colors = {
  part_of: "oklch(55% 0.02 262)",
  follows: "oklch(58% 0.13 200)",
  cause: "oklch(58% 0.19 40)",
  effect: "oklch(55% 0.21 25)",
  significant: "oklch(52% 0.17 300)",
  default: "oklch(60% 0.02 262)"
}

test("happy path: linksSource wraps an empty FeatureCollection", () => {
  const source = linksSource()

  assert.equal(source.type, "geojson")
  assert.deepEqual(source.data, emptyFeatureCollection())
  assert.deepEqual(source.data.features, [])
})

test("happy path: line layer reads its id and source", () => {
  const layer = linksLineLayer({colors, reducedMotion: false})

  assert.equal(layer.id, LINKS_LAYER_ID)
  assert.equal(layer.type, "line")
  assert.equal(layer.source, LINKS_SOURCE_ID)
})

test("happy path: line layer starts hidden", () => {
  const layer = linksLineLayer({colors, reducedMotion: false})

  assert.equal(layer.paint["line-opacity"], HIDDEN_OPACITY)
})

test("happy path: line-color match expression covers all five relation types plus a default", () => {
  const layer = linksLineLayer({colors, reducedMotion: false})
  const expression = layer.paint["line-color"]

  assert.equal(expression[0], "match")
  assert.deepEqual(expression[1], ["get", "link_type"])

  for (const type of LINK_TYPES) {
    const typeIndex = expression.indexOf(type)
    assert.ok(typeIndex > 0, `${type} is covered by the expression`)
    assert.equal(expression[typeIndex + 1], colors[type])
  }

  // The last element of a MapLibre "match" expression is the fallback
  // output, not a [label, output] pair.
  assert.equal(expression.at(-1), colors.default)
})

test("happy path: line-width match expression is heavier for cause and effect", () => {
  const layer = linksLineLayer({colors, reducedMotion: false})
  const expression = layer.paint["line-width"]

  assert.equal(expression[0], "match")

  const causeIndex = expression.indexOf("cause")
  const effectIndex = expression.indexOf("effect")

  assert.equal(expression[causeIndex + 1], expression[effectIndex + 1])
  assert.ok(expression.at(-1) < expression[causeIndex + 1], "default width is lighter")
})

test("happy path: line layer declares a fade-in transition when motion is allowed", () => {
  const layer = linksLineLayer({colors, reducedMotion: false})

  assert.deepEqual(layer.paint["line-opacity-transition"], {duration: 300, delay: 0})
})

test("edge case: reducedMotion variant declares no transition at all", () => {
  const layer = linksLineLayer({colors, reducedMotion: true})

  assert.equal("line-opacity-transition" in layer.paint, false)
})
