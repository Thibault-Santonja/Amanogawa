import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {test} from "node:test"

import {
  colorFor,
  mapLibreColorExpression,
  normalizeYear,
  parseCssColor,
  readGradientTokens
} from "../lib/time_gradient.js"

const TOKENS = {start: {r: 0, g: 0, b: 255}, end: {r: 255, g: 0, b: 0}}

test("happy path: colorFor(0) is exactly the start token", () => {
  assert.equal(colorFor(0, TOKENS), "rgb(0, 0, 255)")
})

test("happy path: colorFor(1) is exactly the end token", () => {
  assert.equal(colorFor(1, TOKENS), "rgb(255, 0, 0)")
})

test("happy path: colorFor(0.5) is the per-channel average", () => {
  assert.equal(colorFor(0.5, TOKENS), "rgb(128, 0, 128)")
})

test("happy path: mapLibreColorExpression's stops carry the token colors", () => {
  const expression = mapLibreColorExpression(-500, 500, TOKENS)

  assert.equal(expression[0], "interpolate")
  assert.deepEqual(expression[1], ["linear"])
  assert.equal(expression[3], 0)
  assert.equal(expression[4], colorFor(0, TOKENS))
  assert.equal(expression[5], 1)
  assert.equal(expression[6], colorFor(1, TOKENS))
})

test("happy path: mapLibreColorExpression's normalization matches (year - from) / (to - from)", () => {
  const expression = mapLibreColorExpression(-500, 500, TOKENS)
  const normalization = expression[2]

  assert.deepEqual(normalization, ["/", ["-", ["get", "year"], -500], 1000])
})

test("edge case: normalizeYear clamps a year before the window to 0", () => {
  assert.equal(normalizeYear(-1000, -500, 500), 0)
})

test("edge case: normalizeYear clamps a year after the window to 1", () => {
  assert.equal(normalizeYear(1000, -500, 500), 1)
})

test("edge case: normalizeYear resolves the window's exact bounds to 0 and 1", () => {
  assert.equal(normalizeYear(-500, -500, 500), 0)
  assert.equal(normalizeYear(500, -500, 500), 1)
})

test("edge case: a degenerate window (from === to) does not divide by zero", () => {
  assert.equal(normalizeYear(1000, 1000, 1000), 0.5)
})

test("edge case: mapLibreColorExpression on a degenerate window uses the literal midpoint", () => {
  const expression = mapLibreColorExpression(1000, 1000, TOKENS)

  assert.equal(expression[2], 0.5)
})

test("error case: readGradientTokens throws on an element with no tokens defined", () => {
  const fakeElement = {}
  const originalGetComputedStyle = globalThis.getComputedStyle

  globalThis.getComputedStyle = () => ({getPropertyValue: () => ""})

  try {
    assert.throws(() => readGradientTokens(fakeElement), /not defined/)
  } finally {
    globalThis.getComputedStyle = originalGetComputedStyle
  }
})

test("parseCssColor: parses oklch(), rgb(), and hex forms", () => {
  assert.deepEqual(parseCssColor("rgb(10, 20, 30)"), {r: 10, g: 20, b: 30})
  assert.deepEqual(parseCssColor("rgb(10 20 30)"), {r: 10, g: 20, b: 30})
  assert.deepEqual(parseCssColor("#0a141e"), {r: 10, g: 20, b: 30})

  // oklch(0% 0 0) is pure black, oklch(100% 0 0) is pure white: exact,
  // gamut-boundary anchors independent of the hue/chroma formulas.
  assert.deepEqual(parseCssColor("oklch(0% 0 0)"), {r: 0, g: 0, b: 0})
  assert.deepEqual(parseCssColor("oklch(100% 0 0)"), {r: 255, g: 255, b: 255})
})

test("parseCssColor: throws on an unrecognized format", () => {
  assert.throws(() => parseCssColor("not-a-color"), /unrecognized CSS color/)
})

// Property (per-channel monotonicity): for t1 < t2 in [0, 1], every
// channel of colorFor moves monotonically between the two extremes (never
// overshoots or oscillates), checked against a spread of endpoint token
// pairs rather than a single fixed one.
test("property: colorFor is monotonic per channel for t1 < t2", () => {
  const tokenPairs = [
    {start: {r: 0, g: 0, b: 255}, end: {r: 255, g: 0, b: 0}},
    {start: {r: 255, g: 255, b: 255}, end: {r: 0, g: 0, b: 0}},
    {start: {r: 12, g: 200, b: 40}, end: {r: 12, g: 200, b: 40}},
    {start: {r: 50, g: 60, b: 70}, end: {r: 200, g: 10, b: 90}}
  ]

  for (const tokens of tokenPairs) {
    const samples = Array.from({length: 21}, (_value, index) => index / 20)
    const colors = samples.map(t => parseCssColor(colorFor(t, tokens)))

    for (const channel of ["r", "g", "b"]) {
      const direction = Math.sign(tokens.end[channel] - tokens.start[channel])

      for (let index = 1; index < colors.length; index += 1) {
        const delta = colors[index][channel] - colors[index - 1][channel]

        if (direction === 0) {
          assert.equal(delta, 0)
        } else {
          assert.ok(delta * direction >= 0, `channel ${channel} regressed between samples`)
        }
      }
    }
  }
})

// --- WCAG contrast verification -------------------------------------
//
// Reads the ACTUAL token values from `assets/css/app.css` (no copy kept
// here: a future palette retouch that breaks accessibility fails this
// test instead of silently drifting from what ships) and checks them
// against the real backgrounds they render on: the vendored map style
// backgrounds (`assets/vendor/map-styles/*.json`, the "fond de carte")
// for the graphical-object threshold (WCAG 1.4.11, >= 3:1), and the UI
// surface token for the legend text threshold (WCAG 1.4.3, >= 4.5:1).

const appCssPath = fileURLToPath(new URL("../../css/app.css", import.meta.url))
const appCss = readFileSync(appCssPath, "utf8")

function cssTokenValues(css, name) {
  const pattern = new RegExp(`--${name}:\\s*([^;]+);`, "g")
  return [...css.matchAll(pattern)].map(match => match[1].trim())
}

// `app.css` declares each token's light value once in `:root` and its
// dark override once inside `@media (prefers-color-scheme: dark)`, in
// that order (verified by `readDesignTokens`'s own callers elsewhere):
// the first match is light, the second is dark.
function lightAndDarkTokens(name) {
  const [light, dark] = cssTokenValues(appCss, name)
  assert.ok(light, `--${name} light value not found in app.css`)
  assert.ok(dark, `--${name} dark value not found in app.css`)
  return {light, dark}
}

function relativeLuminance({r, g, b}) {
  function linearize(channel) {
    const normalized = channel / 255
    return normalized <= 0.03928
      ? normalized / 12.92
      : ((normalized + 0.055) / 1.055) ** 2.4
  }

  return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
}

function contrastRatio(colorA, colorB) {
  const lighter = Math.max(relativeLuminance(colorA), relativeLuminance(colorB))
  const darker = Math.min(relativeLuminance(colorA), relativeLuminance(colorB))
  return (lighter + 0.05) / (darker + 0.05)
}

const mapBackgrounds = {
  light: parseCssColor(readMapStyleBackground("light")),
  dark: parseCssColor(readMapStyleBackground("dark"))
}

function readMapStyleBackground(theme) {
  const stylePath = fileURLToPath(
    new URL(`../../vendor/map-styles/${theme}.json`, import.meta.url)
  )
  const style = JSON.parse(readFileSync(stylePath, "utf8"))
  const backgroundLayer = style.layers.find(layer => layer.type === "background")

  return backgroundLayer.paint["background-color"]
}

const GRAPHICAL_CONTRAST_MINIMUM = 3
const TEXT_CONTRAST_MINIMUM = 4.5

test("limit case: WCAG contrast of --time-start-color/--time-end-color against the map background", () => {
  const startTokens = lightAndDarkTokens("time-start-color")
  const endTokens = lightAndDarkTokens("time-end-color")

  for (const theme of ["light", "dark"]) {
    const start = parseCssColor(startTokens[theme])
    const end = parseCssColor(endTokens[theme])
    const background = mapBackgrounds[theme]

    assert.ok(
      contrastRatio(start, background) >= GRAPHICAL_CONTRAST_MINIMUM,
      `${theme}: --time-start-color vs map background is below ${GRAPHICAL_CONTRAST_MINIMUM}:1`
    )
    assert.ok(
      contrastRatio(end, background) >= GRAPHICAL_CONTRAST_MINIMUM,
      `${theme}: --time-end-color vs map background is below ${GRAPHICAL_CONTRAST_MINIMUM}:1`
    )
  }
})

test("limit case: WCAG contrast of --time-start-color/--time-end-color against the UI surface", () => {
  const startTokens = lightAndDarkTokens("time-start-color")
  const endTokens = lightAndDarkTokens("time-end-color")
  const surfaceTokens = lightAndDarkTokens("palette-surface")

  for (const theme of ["light", "dark"]) {
    const start = parseCssColor(startTokens[theme])
    const end = parseCssColor(endTokens[theme])
    const surface = parseCssColor(surfaceTokens[theme])

    assert.ok(
      contrastRatio(start, surface) >= GRAPHICAL_CONTRAST_MINIMUM,
      `${theme}: --time-start-color vs UI surface is below ${GRAPHICAL_CONTRAST_MINIMUM}:1`
    )
    assert.ok(
      contrastRatio(end, surface) >= GRAPHICAL_CONTRAST_MINIMUM,
      `${theme}: --time-end-color vs UI surface is below ${GRAPHICAL_CONTRAST_MINIMUM}:1`
    )
  }
})

test("limit case: WCAG contrast of the legend's text color against its background", () => {
  const textTokens = lightAndDarkTokens("palette-text-muted")
  const surfaceTokens = lightAndDarkTokens("palette-surface")

  for (const theme of ["light", "dark"]) {
    const text = parseCssColor(textTokens[theme])
    const surface = parseCssColor(surfaceTokens[theme])

    assert.ok(
      contrastRatio(text, surface) >= TEXT_CONTRAST_MINIMUM,
      `${theme}: legend text vs its background is below ${TEXT_CONTRAST_MINIMUM}:1`
    )
  }
})
