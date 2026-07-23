// Pure factories for the MapLibre GeoJSON source and layer rendering the
// typed relations between events (issue #017): a `LineString` per relation,
// filled at selection and cleared at deselection by `assets/js/hooks/
// map_hook.js`. Style expressions only, no MapLibre dependency:
// unit-testable with plain node:test, mirroring `event_layers.js`.
//
// Segments are straight two-point `LineString`s for the MVP (a relation
// crossing the antimeridian draws "the long way around"): a densified
// great-circle arc is deliberately deferred to a later issue, only if the
// straight-segment rendering of long-distance relations turns out to
// justify it visually.

export const LINKS_SOURCE_ID = "event-links"
export const LINKS_LAYER_ID = "event-links-lines"

// The full enumeration of `Amanogawa.Atlas.EventLink.link_type/0`, kept in
// sync by hand across the language boundary.
export const LINK_TYPES = ["part_of", "follows", "cause", "effect", "significant"]

// Causal relations draw a heavier line than purely structural/sequential
// ones, so they read as the more significant connections at a glance.
const HEAVY_LINK_TYPES = ["cause", "effect"]

const FADE_DURATION_MS = 300

export function emptyFeatureCollection() {
  return {type: "FeatureCollection", features: []}
}

// A dedicated source, deliberately never mixed with the `events` point
// source (`event_layers.js`): its lifecycle is independent, filled at
// selection and emptied at deselection, while `events` is refetched on
// every viewport change.
export function linksSource() {
  return {type: "geojson", data: emptyFeatureCollection()}
}

function lineColorExpression(colors) {
  const cases = LINK_TYPES.flatMap(type => [type, colors[type]])
  return ["match", ["get", "link_type"], ...cases, colors.default]
}

function lineWidthExpression() {
  const cases = HEAVY_LINK_TYPES.flatMap(type => [type, 2.5])
  return ["match", ["get", "link_type"], ...cases, 1.5]
}

function fadeTransition(reducedMotion) {
  return reducedMotion ? {} : {duration: FADE_DURATION_MS, delay: 0}
}

function withTransition(paint, property, reducedMotion) {
  const transition = fadeTransition(reducedMotion)

  if (Object.keys(transition).length === 0) return paint

  return {...paint, [`${property}-transition`]: transition}
}

export const HIDDEN_OPACITY = 0
export const VISIBLE_OPACITY = 0.8

// Builds the `event-links-lines` layer: color by relation type from design
// tokens (`.claude/rules/tailwind.md`: no hardcoded hex when a token
// exists), width bumped for causal relations, invisible until the hook
// raises the opacity after a selection's links are loaded. The hook adds
// this layer below the events layers (`beforeId`, see `map_hook.js`) so
// lines never draw over event markers.
export function linksLineLayer({colors, reducedMotion}) {
  const paint = withTransition(
    {
      "line-color": lineColorExpression(colors),
      "line-width": lineWidthExpression(),
      "line-opacity": HIDDEN_OPACITY
    },
    "line-opacity",
    reducedMotion
  )

  return {
    id: LINKS_LAYER_ID,
    type: "line",
    source: LINKS_SOURCE_ID,
    layout: {"line-cap": "round"},
    paint
  }
}
