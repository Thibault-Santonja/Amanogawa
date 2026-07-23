// Shared MapLibre style-building helpers used by both `event_layers.js`
// (issue #015) and `link_layers.js` (issue #017): an empty GeoJSON
// FeatureCollection factory and the fade-in/out paint-property transition
// mechanism (`.claude/rules/tailwind.md`: animations respect
// `prefers-reduced-motion`). Extracted here rather than duplicated across
// the two layer modules, which used to define identical copies of all four
// (security review, code-quality finding). No MapLibre dependency:
// unit-testable with plain node:test.

export function emptyFeatureCollection() {
  return {type: "FeatureCollection", features: []}
}

// Duration (ms) of the fade transition applied to a layer's opacity paint
// property. Omitted entirely (rather than set to a zero duration, see
// `fadeTransition` below) when motion is reduced: no transition definition
// at all.
export const FADE_DURATION_MS = 300

export function fadeTransition(reducedMotion) {
  return reducedMotion ? {} : {duration: FADE_DURATION_MS, delay: 0}
}

// Adds a `${property}-transition` entry to `paint` driving the fade
// declared by `fadeTransition`, or returns `paint` unchanged under reduced
// motion (no transition key at all, rather than a zero-duration one).
export function withTransition(paint, property, reducedMotion) {
  const transition = fadeTransition(reducedMotion)

  if (Object.keys(transition).length === 0) return paint

  return {...paint, [`${property}-transition`]: transition}
}
