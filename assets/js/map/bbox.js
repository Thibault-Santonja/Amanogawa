// Pure conversion of MapLibre map bounds into the `bbox` query parameter
// expected by `GET /api/events` (issue #014): "min_lon,min_lat,max_lon,max_lat".
//
// No MapLibre dependency: callers pass a plain object exposing
// west/south/east/north (built from `map.getBounds()` in the hook), so this
// module is unit-testable with node:test alone.

const WORLD_MIN_LAT = -90
const WORLD_MAX_LAT = 90
const WORLD_WIDTH = 360

// Normalizes a longitude expressed outside [-180, 180] back into the
// canonical range. MapLibre readily returns bounds beyond that range once
// the map has been panned around the globe more than once.
export function normalizeLongitude(lon) {
  let normalized = lon % WORLD_WIDTH

  if (normalized > 180) normalized -= WORLD_WIDTH
  if (normalized < -180) normalized += WORLD_WIDTH

  return normalized
}

function clampLatitude(lat) {
  return Math.min(Math.max(lat, WORLD_MIN_LAT), WORLD_MAX_LAT)
}

function formatCoordinate(value) {
  return Number(value.toFixed(6)).toString()
}

// Converts map bounds (`{west, south, east, north}`, e.g. built from
// `map.getBounds()`) into the API `bbox` string.
//
// Two special cases beyond a nominal conversion:
//
//   - a view spanning the whole globe or more (raw width >= 360, e.g. after
//     zooming all the way out) is capped to the valid world bounds rather
//     than normalized, which would otherwise fold an entire hemisphere into
//     a spurious antimeridian-crossing sliver;
//   - a view crossing the antimeridian normalizes to `min_lon > max_lon` by
//     design, exactly the format `AmanogawaWeb.Params.EventsQuery.parse_bbox/1`
//     decomposes into two envelopes server-side.
//
// Degenerate bounds (zero width or height) are returned as-is: they are a
// legitimate, if unhelpful, viewport, never an error.
export function boundsToBbox(bounds) {
  const south = clampLatitude(bounds.south)
  const north = clampLatitude(bounds.north)
  const [minLat, maxLat] = south <= north ? [south, north] : [north, south]

  const rawWidth = bounds.east - bounds.west

  if (Math.abs(rawWidth) >= WORLD_WIDTH) {
    return `-180,${formatCoordinate(minLat)},180,${formatCoordinate(maxLat)}`
  }

  const west = normalizeLongitude(bounds.west)
  const east = normalizeLongitude(bounds.east)

  return `${formatCoordinate(west)},${formatCoordinate(minLat)},${formatCoordinate(east)},${formatCoordinate(maxLat)}`
}
