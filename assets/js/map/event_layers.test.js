import assert from "node:assert/strict"
import {test} from "node:test"

import {
  EVENTS_CIRCLE_LAYER_ID,
  EVENTS_LABEL_LAYER_ID,
  EVENTS_SOURCE_ID,
  HIDDEN_OPACITY,
  LABEL_MIN_ZOOM,
  OUT_OF_WINDOW_OPACITY,
  VISIBLE_OPACITY,
  emptyFeatureCollection,
  eventsCircleLayer,
  eventsLabelLayer,
  eventsSource,
  textOpacityExpression,
  windowedOpacityExpression
} from "./event_layers.js"

const tokens = {
  accentColor: "oklch(48% 0.16 262)",
  haloColor: "oklch(99% 0.002 120)",
  textColor: "oklch(25% 0.01 262)"
}

test("happy path: eventsSource wraps an empty FeatureCollection and promotes qid as feature id", () => {
  const source = eventsSource()

  assert.equal(source.type, "geojson")
  assert.equal(source.promoteId, "qid")
  assert.deepEqual(source.data, emptyFeatureCollection())
  assert.deepEqual(source.data.features, [])
})

test("happy path: circle layer interpolates radius on zoom and importance", () => {
  const layer = eventsCircleLayer({...tokens, reducedMotion: false})

  assert.equal(layer.id, EVENTS_CIRCLE_LAYER_ID)
  assert.equal(layer.type, "circle")
  assert.equal(layer.source, EVENTS_SOURCE_ID)

  const radius = layer.paint["circle-radius"]
  assert.equal(radius[0], "interpolate")
  assert.deepEqual(radius[2], ["zoom"])

  // Each zoom stop's output is itself an importance interpolation.
  const firstStopOutput = radius[4]
  assert.equal(firstStopOutput[0], "interpolate")
  assert.deepEqual(firstStopOutput[2], ["get", "importance"])
})

test("happy path: circle layer starts hidden and reads colors from design tokens", () => {
  const layer = eventsCircleLayer({...tokens, reducedMotion: false})

  assert.equal(layer.paint["circle-opacity"], HIDDEN_OPACITY)
  assert.equal(layer.paint["circle-color"], tokens.accentColor)
  assert.equal(layer.paint["circle-stroke-color"], tokens.haloColor)
})

test("happy path: circle layer thickens the stroke of the selected feature", () => {
  const layer = eventsCircleLayer({...tokens, reducedMotion: false})
  const strokeWidth = layer.paint["circle-stroke-width"]

  assert.deepEqual(strokeWidth[1], ["boolean", ["feature-state", "selected"], false])
  assert.equal(strokeWidth[2], 3)
  assert.equal(strokeWidth[3], 1)
})

test("happy path: circle layer declares a fade-in transition when motion is allowed", () => {
  const layer = eventsCircleLayer({...tokens, reducedMotion: false})

  assert.deepEqual(layer.paint["circle-opacity-transition"], {duration: 300, delay: 0})
})

test("edge case: reducedMotion variant declares no transition at all", () => {
  const layer = eventsCircleLayer({...tokens, reducedMotion: true})

  assert.equal("circle-opacity-transition" in layer.paint, false)
  assert.equal("circle-color-transition" in layer.paint, false)
})

test("happy path: circle layer uses circleColor over accentColor when both are given (issue #022)", () => {
  const gradientExpression = ["interpolate", ["linear"], ["get", "year"], 0, "rgb(0, 0, 255)"]
  const layer = eventsCircleLayer({...tokens, reducedMotion: false, circleColor: gradientExpression})

  assert.deepEqual(layer.paint["circle-color"], gradientExpression)
})

test("happy path: circle layer falls back to accentColor when circleColor is not given", () => {
  const layer = eventsCircleLayer({...tokens, reducedMotion: false})

  assert.equal(layer.paint["circle-color"], tokens.accentColor)
})

test("happy path: circle layer declares a circle-color transition when motion is allowed", () => {
  const layer = eventsCircleLayer({...tokens, reducedMotion: false})

  assert.deepEqual(layer.paint["circle-color-transition"], {duration: 300, delay: 0})
})

test("happy path: windowedOpacityExpression is visible inside the window, faded outside it", () => {
  const expression = windowedOpacityExpression(-500, 500)

  assert.equal(expression[0], "case")
  assert.deepEqual(expression[1], ["all", [">=", ["get", "year"], -500], ["<=", ["get", "year"], 500]])
  assert.equal(expression[2], VISIBLE_OPACITY)
  assert.equal(expression[3], OUT_OF_WINDOW_OPACITY)
})

test("happy path: label layer is gated by minzoom and the label field reads properties.label", () => {
  const layer = eventsLabelLayer({...tokens, reducedMotion: false})

  assert.equal(layer.id, EVENTS_LABEL_LAYER_ID)
  assert.equal(layer.type, "symbol")
  assert.equal(layer.minzoom, LABEL_MIN_ZOOM)
  assert.deepEqual(layer.layout["text-field"], ["get", "label"])
  assert.equal(layer.paint["text-opacity"], HIDDEN_OPACITY)
})

test("edge case: label reducedMotion variant declares no transition at all", () => {
  const layer = eventsLabelLayer({...tokens, reducedMotion: true})

  assert.equal("text-opacity-transition" in layer.paint, false)
})

test("happy path: textOpacityExpression steps on zoom and gates by importance before zoom 9", () => {
  const expression = textOpacityExpression()

  assert.equal(expression[0], "step")
  assert.deepEqual(expression[1], ["zoom"])
  assert.equal(expression[2], HIDDEN_OPACITY, "hidden before LABEL_MIN_ZOOM")

  const [, , , minZoomStop, minZoomOutput] = expression
  assert.equal(minZoomStop, LABEL_MIN_ZOOM)
  assert.equal(minZoomOutput[0], "case", "gated by an importance case at the zoom floor")
})
