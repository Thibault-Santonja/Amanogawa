import assert from "node:assert/strict"
import {test} from "node:test"

import {FADE_DURATION_MS, emptyFeatureCollection, fadeTransition, withTransition} from "./style_utils.js"

test("happy path: emptyFeatureCollection returns an empty GeoJSON FeatureCollection", () => {
  assert.deepEqual(emptyFeatureCollection(), {type: "FeatureCollection", features: []})
})

test("happy path: fadeTransition returns the documented duration with no delay", () => {
  assert.deepEqual(fadeTransition(false), {duration: FADE_DURATION_MS, delay: 0})
})

test("edge case: fadeTransition returns no transition at all under reduced motion", () => {
  assert.deepEqual(fadeTransition(true), {})
})

test("happy path: withTransition adds a '<property>-transition' entry when motion is allowed", () => {
  const paint = withTransition({"circle-opacity": 0}, "circle-opacity", false)

  assert.deepEqual(paint, {
    "circle-opacity": 0,
    "circle-opacity-transition": {duration: FADE_DURATION_MS, delay: 0}
  })
})

test("edge case: withTransition leaves paint untouched under reduced motion", () => {
  const paint = {"circle-opacity": 0}

  assert.deepEqual(withTransition(paint, "circle-opacity", true), paint)
  assert.equal("circle-opacity-transition" in withTransition(paint, "circle-opacity", true), false)
})
