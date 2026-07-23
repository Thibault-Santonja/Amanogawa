// Pure factories for the MapLibre GeoJSON source and layers rendering
// historical borders (issue #025): semi-transparent fills without a hard
// line layer (ADR 0004: historical borders are academically disputed and
// assumed imprecise, rendered as "zones of influence", never as exact
// lines), plus a label layer restricted to large entities at high zoom.
// Style expressions only, no MapLibre dependency: unit-testable with plain
// node:test, mirroring `event_layers.js`/`link_layers.js`.

import {emptyFeatureCollection, withTransition} from "./style_utils.js"

export {emptyFeatureCollection} from "./style_utils.js"

export const BORDERS_SOURCE_ID = "borders"
export const BORDERS_FILL_LAYER_ID = "borders-fill"
export const BORDERS_LABEL_LAYER_ID = "borders-labels"

// Attribution for the two border sources (issue #025's own task list,
// ADR 0004's licensing obligations: CC BY 4.0 for Cliopatria, GPL-3.0 for
// historical-basemaps): appended to the map's own `AttributionControl`
// (`customAttribution` in `assets/js/hooks/map_hook.js`) alongside the
// basemap's OpenFreeMap/OpenStreetMap credit already declared in
// `assets/vendor/map-styles/{light,dark}.json`.
// `rel="noopener noreferrer"` on every `target="_blank"` link: without
// `noopener`, the opened page gets a `window.opener` handle back into
// this app (reverse tabnabbing). Defined in this pure module (not inline
// in the hook) so the links stay unit-testable without a MapLibre
// instance. `docs/features/006-deploiement/002-page-sources-legal.md`
// covers the full Sources page; this is the map-level minimum.
export const BORDER_SOURCE_ATTRIBUTIONS = [
  '<a href="https://github.com/Seshat-Global-History-Databank/cliopatria" target="_blank" rel="noopener noreferrer">Cliopatria (CC BY 4.0)</a>',
  '<a href="https://github.com/aourednik/historical-basemaps" target="_blank" rel="noopener noreferrer">historical-basemaps (GPL-3.0)</a>'
]

// Fills start invisible: the hook raises this to `VISIBLE_OPACITY` on the
// next animation frame after every `setData` (first load and every
// subsequent year change alike), letting `fill-opacity-transition` (below)
// animate the change as a cross-fade rather than a hard cut (issue #025's
// own "transition douce au changement d'année").
export const HIDDEN_OPACITY = 0

// Deliberately low (issue #025: "aplats semi-transparents", "frontières
// floues assumées"): two overlapping polities must stay readable as a
// visibly darker overlap of their two hues, not a single opaque block, and
// the map's own base layers and event markers must remain legible through
// the fill.
export const VISIBLE_OPACITY = 0.25

// Labels never appear below this zoom, mirroring `event_layers.js`'s own
// `LABEL_MIN_ZOOM`: borders render *under* events (see
// `assets/js/hooks/map_hook.js`'s layer setup order) and their labels
// should only ever compete with event labels once the viewer has zoomed in
// enough for both to coexist without turning into label soup.
export const LABEL_MIN_ZOOM = 4

// Only "large entities" get a label (issue #025's own task list): an empire
// or a major kingdom, not every minor polygon a dense year can carry.
// 500,000 km^2 is roughly the size of a large present-day country (France
// is ~551,000 km^2): a deliberately coarse, easy-to-reason-about threshold
// rather than a percentile computed per response, which would make the set
// of labeled entities (and therefore the map's visual density) vary
// unpredictably from one year to the next.
export const LABEL_MIN_AREA_KM2 = 500_000

// A dedicated source: its lifecycle (one `setData` per reference year, see
// `assets/js/hooks/map_hook.js#fetchBorders`) is independent from `events`
// (refetched on viewport change) and `event-links` (filled/emptied at
// selection).
export function bordersSource() {
  return {type: "geojson", data: emptyFeatureCollection()}
}

// Builds the `borders-fill` layer: color read directly from each feature's
// server-computed `properties.color` (`Amanogawa.Atlas.PolityColor`, an
// `hsl()` string MapLibre's color parser accepts natively) via a `["get",
// "color"]` expression, never recomputed or duplicated in JS (issue #025's
// own point d'attention). No matching `line` layer exists anywhere in this
// module: the fill alone is the deliberate rendering choice.
export function bordersFillLayer({reducedMotion}) {
  const paint = withTransition(
    {
      "fill-color": ["get", "color"],
      "fill-opacity": HIDDEN_OPACITY
    },
    "fill-opacity",
    reducedMotion
  )

  return {id: BORDERS_FILL_LAYER_ID, type: "fill", source: BORDERS_SOURCE_ID, paint}
}

// Builds the `borders-labels` layer: `text-field` on the polity name,
// shown only above `LABEL_MIN_ZOOM` AND for features whose `area_km2`
// clears `LABEL_MIN_AREA_KM2` (the `filter`, evaluated by MapLibre against
// every candidate feature; collisions between overlapping labels are left
// to MapLibre, matching `event_layers.js`'s own approach). Text/halo colors
// come from the same design tokens as every other map label, no hardcoded
// hex (`.claude/rules/tailwind.md`).
export function bordersLabelLayer({textColor, haloColor}) {
  return {
    id: BORDERS_LABEL_LAYER_ID,
    type: "symbol",
    source: BORDERS_SOURCE_ID,
    minzoom: LABEL_MIN_ZOOM,
    filter: [">=", ["get", "area_km2"], LABEL_MIN_AREA_KM2],
    layout: {
      "text-field": ["get", "name"],
      "text-size": 11,
      "text-justify": "auto",
      "text-optional": true
    },
    paint: {
      "text-color": textColor,
      "text-halo-color": haloColor,
      "text-halo-width": 1
    }
  }
}
