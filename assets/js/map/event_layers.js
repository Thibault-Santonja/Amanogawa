// Pure factories for the MapLibre GeoJSON source and layers rendering
// historical events (issue #015). Style expressions only, no MapLibre
// dependency: unit-testable with plain node:test, wired into the map by
// `assets/js/hooks/map_hook.js`.

export const EVENTS_SOURCE_ID = "events"
export const EVENTS_CIRCLE_LAYER_ID = "events-circles"
export const EVENTS_LABEL_LAYER_ID = "events-labels"

// Labels never appear below this zoom regardless of importance: a hard
// floor on top of the importance-driven `text-opacity` step below, so the
// map never turns into label soup while zoomed out on the whole world.
export const LABEL_MIN_ZOOM = 3

// Paint-property transition applied to circle/text opacity, the mechanism
// behind the marker fade-in (`.claude/rules/tailwind.md`: animations
// respect `prefers-reduced-motion`). Omitted entirely (rather than set to a
// zero duration) when motion is reduced: no transition definition at all.
const FADE_DURATION_MS = 300

export function emptyFeatureCollection() {
  return {type: "FeatureCollection", features: []}
}

// `promoteId` lets the hook address a feature by its `qid` property
// through `map.setFeatureState`, used for the selection highlight
// (issue #018 point d'attention: pose the selection contract without
// building #016's full event panel).
export function eventsSource() {
  return {type: "geojson", data: emptyFeatureCollection(), promoteId: "qid"}
}

function fadeTransition(reducedMotion) {
  return reducedMotion ? {} : {duration: FADE_DURATION_MS, delay: 0}
}

function withTransition(paint, property, reducedMotion) {
  const transition = fadeTransition(reducedMotion)

  if (Object.keys(transition).length === 0) return paint

  return {...paint, [`${property}-transition`]: transition}
}

// Circle radius grows with both zoom (small points far out, plain circles
// close in) and importance (`sitelink_count`, more sitelinks means a
// visually heavier marker at any given zoom).
function circleRadiusExpression() {
  return [
    "interpolate",
    ["linear"],
    ["zoom"],
    2,
    ["interpolate", ["linear"], ["get", "importance"], 0, 1.5, 50, 2.5, 300, 4],
    6,
    ["interpolate", ["linear"], ["get", "importance"], 0, 2.5, 50, 4.5, 300, 7],
    12,
    ["interpolate", ["linear"], ["get", "importance"], 0, 4, 50, 7, 300, 12]
  ]
}

// Circles start invisible: the hook raises this property to 1 once the
// first `setData` for the current style completes, letting the
// `circle-opacity-transition` above animate the fade-in.
export const HIDDEN_OPACITY = 0
export const VISIBLE_OPACITY = 1

// Builds the `events-circles` layer: marker size by importance and zoom,
// color from design tokens (`.claude/rules/tailwind.md`: no hardcoded hex
// when a token exists), invisible until the hook raises the opacity after
// the first data load.
export function eventsCircleLayer({accentColor, haloColor, reducedMotion}) {
  const paint = withTransition(
    {
      "circle-radius": circleRadiusExpression(),
      "circle-color": accentColor,
      // A selected event (issue #018: `event_selected`/`event_deselected`
      // pushed by the LiveView, applied through `setFeatureState`) draws a
      // thicker halo than the rest.
      "circle-stroke-width": ["case", ["boolean", ["feature-state", "selected"], false], 3, 1],
      "circle-stroke-color": haloColor,
      "circle-opacity": HIDDEN_OPACITY
    },
    "circle-opacity",
    reducedMotion
  )

  return {id: EVENTS_CIRCLE_LAYER_ID, type: "circle", source: EVENTS_SOURCE_ID, paint}
}

// Label visibility combines a hard zoom floor (`minzoom`) with a step on
// importance: major events (high `sitelink_count`) get a label earlier
// (lower zoom) than ordinary ones, avoiding visual clutter while zoomed
// out. Collision handling (overlapping labels) is left to MapLibre.
//
// Exported: the layer starts with `text-opacity` flattened to
// `HIDDEN_OPACITY` (see `eventsLabelLayer` below), the hook raises it to
// this expression after the first `setData`, so the `text-opacity-transition`
// fades every label in at its rightful, zoom/importance-gated opacity
// rather than jumping straight from 0 to a plain 1.
export function textOpacityExpression() {
  return [
    "step",
    ["zoom"],
    HIDDEN_OPACITY,
    LABEL_MIN_ZOOM,
    ["case", [">=", ["get", "importance"], 200], VISIBLE_OPACITY, HIDDEN_OPACITY],
    6,
    ["case", [">=", ["get", "importance"], 50], VISIBLE_OPACITY, HIDDEN_OPACITY],
    9,
    VISIBLE_OPACITY
  ]
}

// Builds the `events-labels` layer: `text-field` on the localized label,
// invisible until the hook raises `text-opacity` to `textOpacityExpression()`
// after the first data load (fade-in, mirrors the circle layer above).
export function eventsLabelLayer({textColor, haloColor, reducedMotion}) {
  const paint = withTransition(
    {
      "text-color": textColor,
      "text-halo-color": haloColor,
      "text-halo-width": 1,
      "text-opacity": HIDDEN_OPACITY
    },
    "text-opacity",
    reducedMotion
  )

  return {
    id: EVENTS_LABEL_LAYER_ID,
    type: "symbol",
    source: EVENTS_SOURCE_ID,
    minzoom: LABEL_MIN_ZOOM,
    layout: {
      "text-field": ["get", "label"],
      "text-size": 12,
      "text-variable-anchor": ["top", "bottom", "left", "right"],
      "text-radial-offset": 0.6,
      "text-justify": "auto",
      "text-optional": true,
      "symbol-sort-key": ["-", 0, ["get", "importance"]]
    },
    paint
  }
}
