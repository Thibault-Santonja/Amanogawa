import assert from "node:assert/strict"
import {test} from "node:test"

import {boundsToBbox, normalizeLongitude, normalizedMapMovedPayload} from "./bbox.js"

test("happy path: nominal bounds convert to min_lon,min_lat,max_lon,max_lat", () => {
  const bounds = {west: 2, south: 48, east: 3, north: 49}

  assert.equal(boundsToBbox(bounds), "2,48,3,49")
})

test("edge case: bounds crossing the antimeridian normalize to min_lon > max_lon", () => {
  const bounds = {west: 170, south: -10, east: 190, north: 10}

  assert.equal(boundsToBbox(bounds), "170,-10,-170,10")
})

test("edge case: longitudes beyond [-180, 180] are normalized back into range", () => {
  const bounds = {west: 370, south: 10, east: 380, north: 20}

  assert.equal(boundsToBbox(bounds), "10,10,20,20")
})

test("edge case: a whole-world view (raw width >= 360) is capped to valid world bounds", () => {
  const bounds = {west: -200, south: -80, east: 200, north: 80}

  assert.equal(boundsToBbox(bounds), "-180,-80,180,80")
})

test("edge case: latitude is clamped and reordered when north/south are swapped", () => {
  const bounds = {west: 0, south: 95, east: 1, north: -95}

  assert.equal(boundsToBbox(bounds), "0,-90,1,90")
})

test("error case: degenerate bounds (zero width) do not throw", () => {
  const bounds = {west: 5, south: 45, east: 5, north: 45}

  assert.doesNotThrow(() => boundsToBbox(bounds))
  assert.equal(boundsToBbox(bounds), "5,45,5,45")
})

test("normalizeLongitude keeps exact world bounds unchanged", () => {
  assert.equal(normalizeLongitude(-180), -180)
  assert.equal(normalizeLongitude(180), 180)
  assert.equal(normalizeLongitude(0), 0)
})

test("normalizeLongitude wraps multiples of a full globe", () => {
  assert.equal(normalizeLongitude(190), -170)
  assert.equal(normalizeLongitude(-190), 170)
  assert.equal(normalizeLongitude(540), 180)
})

test("happy path: normalizedMapMovedPayload passes zoom/lat through and normalizes lng", () => {
  assert.deepEqual(normalizedMapMovedPayload(4.5, 10, 20), {z: 4.5, lat: 10, lng: 20})
})

test("edge case: normalizedMapMovedPayload wraps a longitude past a full globe pan", () => {
  // A center longitude beyond [-180, 180], as MapLibre's getCenter() readily
  // returns after panning around the globe more than once.
  assert.deepEqual(normalizedMapMovedPayload(3, 10, 190), {z: 3, lat: 10, lng: -170})
})
