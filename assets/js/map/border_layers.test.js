import assert from "node:assert/strict"
import {test} from "node:test"

import {
  BORDERS_FILL_LAYER_ID,
  BORDERS_LABEL_LAYER_ID,
  BORDERS_SOURCE_ID,
  HIDDEN_OPACITY,
  LABEL_MIN_AREA_KM2,
  LABEL_MIN_ZOOM,
  VISIBLE_OPACITY,
  bordersFillLayer,
  bordersLabelLayer,
  bordersSource,
  emptyFeatureCollection
} from "./border_layers.js"

const tokens = {textColor: "rgb(10, 10, 10)", haloColor: "rgb(250, 250, 250)"}

test("happy path: bordersSource wraps an empty FeatureCollection", () => {
  const source = bordersSource()

  assert.equal(source.type, "geojson")
  assert.deepEqual(source.data, emptyFeatureCollection())
  assert.deepEqual(source.data.features, [])
})

test("happy path: fill layer reads its id, type and source", () => {
  const layer = bordersFillLayer({reducedMotion: false})

  assert.equal(layer.id, BORDERS_FILL_LAYER_ID)
  assert.equal(layer.type, "fill")
  assert.equal(layer.source, BORDERS_SOURCE_ID)
})

test("happy path: fill layer reads color from properties.color, never a hardcoded value", () => {
  const layer = bordersFillLayer({reducedMotion: false})

  assert.deepEqual(layer.paint["fill-color"], ["get", "color"])
})

test("happy path: fill layer starts hidden", () => {
  const layer = bordersFillLayer({reducedMotion: false})

  assert.equal(layer.paint["fill-opacity"], HIDDEN_OPACITY)
})

test("happy path: fill layer declares a fade transition when motion is allowed", () => {
  const layer = bordersFillLayer({reducedMotion: false})

  assert.deepEqual(layer.paint["fill-opacity-transition"], {duration: 300, delay: 0})
})

test("edge case: reducedMotion variant declares no transition at all", () => {
  const layer = bordersFillLayer({reducedMotion: true})

  assert.equal("fill-opacity-transition" in layer.paint, false)
})

test("edge case: no line layer is ever built by this module (ADR 0004, no hard border line)", () => {
  const fillLayer = bordersFillLayer({reducedMotion: false})
  const labelLayer = bordersLabelLayer(tokens)

  assert.notEqual(fillLayer.type, "line")
  assert.notEqual(labelLayer.type, "line")
})

test("happy path: label layer reads its id, type, source and minzoom", () => {
  const layer = bordersLabelLayer(tokens)

  assert.equal(layer.id, BORDERS_LABEL_LAYER_ID)
  assert.equal(layer.type, "symbol")
  assert.equal(layer.source, BORDERS_SOURCE_ID)
  assert.equal(layer.minzoom, LABEL_MIN_ZOOM)
})

test("happy path: label layer filters on area_km2 to only large entities", () => {
  const layer = bordersLabelLayer(tokens)

  assert.deepEqual(layer.filter, [">=", ["get", "area_km2"], LABEL_MIN_AREA_KM2])
})

test("happy path: label layer reads the polity name and design tokens", () => {
  const layer = bordersLabelLayer(tokens)

  assert.deepEqual(layer.layout["text-field"], ["get", "name"])
  assert.equal(layer.paint["text-color"], tokens.textColor)
  assert.equal(layer.paint["text-halo-color"], tokens.haloColor)
})

test("happy path: VISIBLE_OPACITY is a low, semi-transparent value (ADR 0004: no hard border)", () => {
  assert.ok(VISIBLE_OPACITY > 0)
  assert.ok(VISIBLE_OPACITY < 0.5)
})
