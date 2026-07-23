// Shared temporal gradient (issue #022): the single definition of "what
// color does an event at year Y get, inside the window [from, to]",
// applied identically at the three places that render it (the map
// markers, `assets/js/hooks/map_hook.js`; the timeline window fill,
// `assets/js/hooks/timeline.js`; the legend,
// `AmanogawaWeb.Components.TimeLegend`).
//
// THE CONVENTION (documented here once, authoritative for all three):
//
//   1. Normalization is LINEAR in years within the window, never symlog:
//      `t = (year - from) / (to - from)`, clamped to `[0, 1]`. The axis
//      encodes an event's position in history (symlog, `time_scale.js`);
//      the gradient encodes its position within the *currently selected
//      window* (linear). Do not "fix" one convention with the other: a
//      wide window stretched across the symlog axis still colors linearly
//      by year, which is the intended reading ("how far into this slice of
//      time"), not a distorted echo of the axis.
//   2. Interpolation between the two endpoint colors is per-channel sRGB,
//      matching the default (unspecified) interpolation color space of
//      MapLibre's `["interpolate", ["linear"], ...]`, of a CSS
//      `linear-gradient()` with no explicit `in <space>`, and of the
//      manual channel-wise interpolation `colorFor` below performs. Do not
//      add `in oklch`/`in srgb-linear` to a CSS gradient using these
//      tokens, and do not switch `colorFor` to interpolate in any other
//      space: the three engines would visibly diverge.
//   3. The two endpoint colors are read from the CSS custom properties
//      `--time-start-color`/`--time-end-color` (`assets/css/app.css`,
//      `.claude/rules/tailwind.md`'s single source of truth). MapLibre
//      cannot read CSS custom properties itself, so every caller resolves
//      them in JS (`readGradientTokens`) before building a style
//      expression, and re-resolves them on every theme change (custom
//      properties differ between `prefers-color-scheme: light`/`dark`).
//
// No dependency, no MapLibre import: pure and testable under plain
// `node:test`, exactly like `time_scale.js`/`time_format.js`.

// Custom DOM event through which `TimelineHook` broadcasts the window
// currently being previewed (mid drag, before the 150ms debounce commits
// it to the server) so `MapHook` can recolor markers immediately without
// waiting on a round trip: purely a client-side rendering optimism, it
// never triggers a data refetch (`.claude/rules/liveview.md`: no re-fetch
// before the debounce). Both hooks import this single constant rather than
// each hardcoding the event name, so a typo in either could never
// desynchronize silently.
export const TIME_WINDOW_PREVIEW_EVENT = "amanogawa:time-window-preview"

function clamp(value, min, max) {
  if (value < min) return min
  if (value > max) return max
  return value
}

// Converts an OKLCH color (`l` in [0, 1], `c` chroma, `h` hue in degrees)
// to 8-bit sRGB, following Björn Ottosson's OKLab reference formulas
// (https://bottosson.github.io/posts/oklab/): OKLCH -> OKLab -> LMS ->
// linear sRGB -> gamma-encoded sRGB. Out-of-gamut channels clamp to
// `[0, 255]` rather than producing an invalid color.
function oklchToRgb(l, c, h) {
  const hueRadians = (h * Math.PI) / 180
  const a = c * Math.cos(hueRadians)
  const b = c * Math.sin(hueRadians)

  const lPrime = l + 0.3963377774 * a + 0.2158037573 * b
  const mPrime = l - 0.1055613458 * a - 0.0638541728 * b
  const sPrime = l - 0.0894841775 * a - 1.2914855480 * b

  const lCubed = lPrime ** 3
  const mCubed = mPrime ** 3
  const sCubed = sPrime ** 3

  const rLinear = 4.0767416621 * lCubed - 3.3077115913 * mCubed + 0.2309699292 * sCubed
  const gLinear = -1.2684380046 * lCubed + 2.6097574011 * mCubed - 0.3413193965 * sCubed
  const bLinear = -0.0041960863 * lCubed - 0.7034186147 * mCubed + 1.707614701 * sCubed

  return {r: gammaEncode(rLinear), g: gammaEncode(gLinear), b: gammaEncode(bLinear)}
}

function gammaEncode(linearChannel) {
  const clamped = clamp(linearChannel, 0, 1)
  const encoded =
    clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * clamped ** (1 / 2.4) - 0.055

  return Math.round(clamp(encoded, 0, 1) * 255)
}

// Parses a CSS color string into `{r, g, b}` (8-bit channels). Supports
// `oklch()` (the format the project's own tokens use), `rgb()`/`rgba()`
// (both comma and space syntax), and `#rrggbb` hex, which covers both what
// `getComputedStyle` returns for a custom property (verbatim, as written
// in `app.css`) and any fixture color a test compares against (e.g. the
// vendored map style backgrounds, `assets/vendor/map-styles/*.json`, which
// are already plain `rgb()`).
export function parseCssColor(value) {
  const trimmed = value.trim()

  const oklchMatch = trimmed.match(
    /^oklch\(\s*([\d.]+)(%)?\s+([\d.]+)\s+([\d.]+)/i
  )
  if (oklchMatch) {
    const [, magnitude, percentSign, chroma, hue] = oklchMatch
    const lightness = Number.parseFloat(magnitude) / (percentSign ? 100 : 1)
    return oklchToRgb(lightness, Number.parseFloat(chroma), Number.parseFloat(hue))
  }

  const rgbMatch = trimmed.match(/^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)/i)
  if (rgbMatch) {
    const [, r, g, b] = rgbMatch
    return {
      r: Math.round(Number.parseFloat(r)),
      g: Math.round(Number.parseFloat(g)),
      b: Math.round(Number.parseFloat(b))
    }
  }

  const hexMatch = trimmed.match(/^#([0-9a-f]{6})$/i)
  if (hexMatch) {
    const int = Number.parseInt(hexMatch[1], 16)
    return {r: (int >> 16) & 255, g: (int >> 8) & 255, b: int & 255}
  }

  throw new Error(`time_gradient: unrecognized CSS color "${value}"`)
}

// Reads `--time-start-color`/`--time-end-color` off `element` (typically
// `document.documentElement`) and parses them into `{start, end}` RGB
// tokens. Throws explicitly when either is missing or unparseable: a
// silent fallback to black would make a broken gradient invisible in
// production instead of failing loudly in development
// (`.claude/rules/tailwind.md`'s "no hardcoded fallback" spirit).
export function readGradientTokens(element) {
  const style = getComputedStyle(element)
  const startRaw = style.getPropertyValue("--time-start-color").trim()
  const endRaw = style.getPropertyValue("--time-end-color").trim()

  if (!startRaw || !endRaw) {
    throw new Error(
      "time_gradient: --time-start-color/--time-end-color are not defined on the given element"
    )
  }

  return {start: parseCssColor(startRaw), end: parseCssColor(endRaw)}
}

// Normalizes `year` linearly within `[from, to]`, clamped to `[0, 1]`
// (convention #1 above). A degenerate window (`from === to`) has no
// meaningful "position within": rather than dividing by zero, every event
// resolves to the gradient's midpoint (`0.5`), documented here as the
// single defined behavior for that case.
export function normalizeYear(year, from, to) {
  if (from === to) return 0.5

  return clamp((year - from) / (to - from), 0, 1)
}

// Interpolates between `tokens.start` and `tokens.end`, per channel, in
// sRGB (convention #2 above), for `t` in `[0, 1]` (clamped). Returns a
// plain `rgb()` CSS color string, valid wherever a MapLibre paint color,
// an SVG `fill`, or a CSS custom property value is expected.
export function colorFor(t, tokens) {
  const clamped = clamp(t, 0, 1)

  const r = Math.round(tokens.start.r + (tokens.end.r - tokens.start.r) * clamped)
  const g = Math.round(tokens.start.g + (tokens.end.g - tokens.start.g) * clamped)
  const b = Math.round(tokens.start.b + (tokens.end.b - tokens.start.b) * clamped)

  return `rgb(${r}, ${g}, ${b})`
}

// Builds a MapLibre `["interpolate", ["linear"], ...]` color expression
// that recolors the `events-circles` layer's `circle-color` from
// `tokens.start` at `from` to `tokens.end` at `to`, reading each feature's
// `year` property (already present in the events GeoJSON, issue #014).
// The normalization sub-expression is the literal MapLibre translation of
// `normalizeYear` above (`(year - from) / (to - from)`): the two must stay
// in lockstep, since `normalizeYear` is what the timeline window and the
// legend use for the exact same year.
//
// A degenerate window (`from === to`) cannot become a MapLibre division
// expression (`to - from` would be a literal `0`): the normalized input is
// replaced with the literal `0.5`, matching `normalizeYear`'s own
// documented degenerate behavior.
export function mapLibreColorExpression(from, to, tokens) {
  const startColor = colorFor(0, tokens)
  const endColor = colorFor(1, tokens)

  const normalizedYear =
    from === to ? 0.5 : ["/", ["-", ["get", "year"], from], to - from]

  return ["interpolate", ["linear"], normalizedYear, 0, startColor, 1, endColor]
}
