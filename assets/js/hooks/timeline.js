// LiveView hook rendering the timeline strip in the layout's
// `footer#timeline` (issue #020): a symlog-graduated axis (d3-axis over
// `assets/js/lib/time_scale.js`'s pure position math), a density
// histogram fetched from `GET /api/events/histogram`, and (issue #021) an
// interactive time window drawn in the reserved `window` SVG layer:
// draggable edges (resize), a draggable body (translate at constant
// width), and a keyboard-operable ARIA slider pair.
//
// Rendering model (F04 design decision D2): the strip is a STATIC
// full-domain frise. The axis is graduated over the whole domain
// (independent of the current window), and the histogram is fetched ONCE
// over the whole domain (refetched only when a resize significantly
// changes the bucket count worth drawing, never on a drag or a window
// change). The time window is only a highlight brushed on top of that
// static background (the gradient-filled body rectangle and its two
// handles), so moving it costs zero network round trips and never
// re-lays-out the axis under the user's cursor.
//
// Domain (F04 design decision D1): the hook never hardcodes the temporal
// bounds. `AmanogawaWeb.ExploreLive` renders the single server-side
// domain (`Amanogawa.Atlas.TimeScale.default/0`, `[-300000, current
// year]`) as `data-domain-min`/`data-domain-max`, and this hook builds
// its scale from those attributes (`readDomain`).
//
// State (the current time window) is owned by the LiveView (ADR 0005,
// issue #018): a local drag never mutates it directly. Client -> server,
// the debounced gesture pushes `select_time_window` (150ms after the last
// movement, and always once more on `pointerup`); server -> client, the
// existing `set_time_window` push (shared with the map hook,
// `assets/js/hooks/map_hook.js`) repositions the window here. The window's
// own constraint math (resize/translate against the domain and the
// minimum width) lives in the pure `assets/js/lib/time_window.js`, tested
// independently of the DOM; this hook only wires Pointer Events and
// keydown to that math and to rendering.
//
// Volumes (the histogram counts) never go through LiveView diffs
// (`.claude/rules/liveview.md`): this hook fetches its own data and holds
// it only for the duration of a render, exactly like the map hook's event
// GeoJSON.
import {axisBottom} from "d3-axis"
import {scaleLinear} from "d3-scale"
import {select} from "d3-selection"

import {TIME_WINDOW_PREVIEW_EVENT, colorFor, readGradientTokens} from "../lib/time_gradient.js"
import {DEFAULT_AXIS_TEMPLATES, formatAxisYear} from "../lib/time_format.js"
import {createTimeScale} from "../lib/time_scale.js"
import {clampWindow, resizeEdge, translateWindow} from "../lib/time_window.js"
import {createEchoGuard} from "../lib/window_echo.js"

// Roughly one graduation per this many pixels of axis width, per issue
// #020 ("nombre de graduations cible proportionnel à la largeur").
const PIXELS_PER_TICK = 80
const MIN_TICK_COUNT = 2

const MARGIN = {top: 8, right: 16, bottom: 20, left: 16}
const HISTOGRAM_HEIGHT_RATIO = 0.55

// Time between the last `ResizeObserver` callback and the next render:
// matches the map hook's own debounce constant
// (`.claude/rules/liveview.md`: debounce before a data refetch). Issue
// #021 reuses this exact constant for the window drag's own debounce
// (`pushEvent("select_time_window", ...)`, 150ms after the last movement):
// one debounce duration for every client intent this hook pushes.
const RESIZE_DEBOUNCE_MS = 150

// Histogram resolution (F04 decision D2): the bucket count adapts to the
// rendered width (about one bucket per `PIXELS_PER_HISTOGRAM_BUCKET`
// pixels), quantized to steps of `HISTOGRAM_BUCKET_STEP` so only a
// *significant* resize (roughly 200px or more) changes the count and
// triggers a refetch; a minor resize re-renders the bars it already has.
// Bounded by the server's own `buckets` cap
// (`AmanogawaWeb.Params.HistogramQuery`, 200).
const PIXELS_PER_HISTOGRAM_BUCKET = 10
const HISTOGRAM_BUCKET_STEP = 20
const MIN_HISTOGRAM_BUCKETS = 20
const MAX_HISTOGRAM_BUCKETS = 200

// The window's minimum width in years (issue #021's own default) and the
// domain-independent constraint logic it is enforced through
// (`assets/js/lib/time_window.js`). Mirrors, but is not shared with,
// `AmanogawaWeb.Params.ExploreParams`'s own minimum: the two enforce the
// same rule on either side of the wire, on the same domain since F04
// decision D1 (see `time_window.js`'s own header).
const MIN_WINDOW_WIDTH_YEARS = 1

// Hit-target sizing for the window's edge handles (WAI-ARIA slider
// pattern, issue #021's own "zones de hit élargies" requirement): at
// least 12px wide and 44px tall regardless of how thin the visual
// indicator or how short the timeline strip actually renders.
const HANDLE_HIT_WIDTH_PX = 12
const HANDLE_MIN_HIT_HEIGHT_PX = 44

// Opacity of the window body's gradient fill: tinted, not opaque, so the
// histogram bars underneath (and the axis labels above, issue #021's own
// "au-dessus de l'histogramme, en dessous des libellés d'axe" ordering)
// stay legible through it.
const WINDOW_FILL_OPACITY = 0.22

function readDesignTokens() {
  const rootStyle = getComputedStyle(document.documentElement)

  return {
    textColor: rootStyle.getPropertyValue("--palette-text").trim(),
    mutedColor: rootStyle.getPropertyValue("--palette-text-muted").trim(),
    borderColor: rootStyle.getPropertyValue("--palette-border").trim(),
    accentColor: rootStyle.getPropertyValue("--palette-accent").trim(),
    gradientTokens: readGradientTokens(document.documentElement)
  }
}

// Debounce identical to `assets/js/map/debounce.js`'s, duplicated here
// deliberately narrow (trailing-edge, cancellable) rather than imported
// across the `map/`/`lib/` module boundary: `lib/` stays free of any
// dependency on `map/`, keeping the two hooks independently movable.
function debounce(fn, delayMs) {
  let timer = null

  function debounced(...args) {
    if (timer !== null) clearTimeout(timer)
    timer = setTimeout(() => {
      timer = null
      fn(...args)
    }, delayMs)
  }

  debounced.cancel = () => {
    if (timer !== null) {
      clearTimeout(timer)
      timer = null
    }
  }

  return debounced
}

// The time-window domain read off the hook element's `data-domain-min`/
// `data-domain-max` attributes (F04 decision D1: the server is the single
// source of these bounds). A missing or malformed attribute falls back to
// `time_scale.js`'s own defaults, which mirror the server's. Exported for
// the `node:test` suite.
export function readDomain(dataset) {
  const fallback = createTimeScale()

  return {
    minYear: parseYear(dataset.domainMin, fallback.minYear),
    maxYear: parseYear(dataset.domainMax, fallback.maxYear)
  }
}

// The initial time window read off `data-from`/`data-to`, clamped into
// `domain` (a URL may legitimately carry no window at all, and a hostile
// or stale one must degrade to the domain edge, never crash or fetch out
// of bounds). Exported for the `node:test` suite (F04 correction M1: the
// mount-time clamp is what guarantees the very first histogram request
// is in bounds).
export function initialTimeWindow(dataset, domain) {
  const raw = {
    from: parseYear(dataset.from, domain.minYear),
    to: parseYear(dataset.to, domain.maxYear)
  }

  return clampWindow(raw, domain, MIN_WINDOW_WIDTH_YEARS)
}

// The adaptive histogram bucket count for a rendered width (F04 decision
// D2, see the constants above). Exported for the `node:test` suite.
export function histogramBucketCount(width) {
  const innerWidth = Math.max(width - MARGIN.left - MARGIN.right, 0)
  const quantized =
    Math.round(innerWidth / PIXELS_PER_HISTOGRAM_BUCKET / HISTOGRAM_BUCKET_STEP) *
    HISTOGRAM_BUCKET_STEP

  return Math.min(Math.max(quantized, MIN_HISTOGRAM_BUCKETS), MAX_HISTOGRAM_BUCKETS)
}

const TimelineHook = {
  mounted() {
    const domain = readDomain(this.el.dataset)
    this.timeScale = createTimeScale({minYear: domain.minYear, maxYear: domain.maxYear})
    this.timeWindow = initialTimeWindow(this.el.dataset, domain)

    // Translated labels served by the server (`AmanogawaWeb.TimelineI18n`
    // through `data-i18n-*`, F04 quality finding m6), falling back to the
    // French source-locale defaults when an attribute is missing.
    this.i18n = {
      templates: {
        kaBp: this.el.dataset.i18nKaBp || DEFAULT_AXIS_TEMPLATES.kaBp,
        century: this.el.dataset.i18nCentury || DEFAULT_AXIS_TEMPLATES.century,
        bce: this.el.dataset.i18nBce || DEFAULT_AXIS_TEMPLATES.bce
      },
      windowStart: this.el.dataset.i18nWindowStart || "Début de la fenêtre",
      windowEnd: this.el.dataset.i18nWindowEnd || "Fin de la fenêtre"
    }

    this.motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.darkScheme = window.matchMedia("(prefers-color-scheme: dark)")

    this.abortController = null
    this.histogram = null
    // Bucket count of the last histogram request sent (F04 decision D2):
    // the histogram covers the full domain, so this is the only thing a
    // refetch can change; `maybeFetchHistogram` refetches exactly when it
    // differs (first fetch included, `null` matches nothing).
    this.lastFetchedBuckets = null

    // The window drag/keyboard gesture in progress, or `null`: `{kind:
    // "resize", edge: "from"|"to", pointerId, startClientX, startWindow}`
    // for a handle drag, `{kind: "translate", pointerId, startClientX,
    // startWindow}` for the body. `startWindow` is `this.timeWindow`
    // clamped into this scale's domain at the moment the gesture began
    // (`clampWindow`, `assets/js/lib/time_window.js`): every delta during
    // the gesture is computed against this fixed snapshot, never against
    // the live (already-updated) `this.timeWindow`, so a fast drag never
    // accumulates rounding error step over step.
    this.drag = null

    // The DOM node this gesture is captured on (`setPointerCapture`),
    // read back to release capture on `pointerup`/`pointercancel`.
    this.dragTarget = null

    // Last window broadcast through `TIME_WINDOW_PREVIEW_EVENT`
    // (`assets/js/lib/time_gradient.js`, issue #022): deduplicates the
    // dispatch so an unrelated re-render (a resize, a theme flip) does not
    // re-notify `MapHook` with an unchanged window.
    this.lastDispatchedWindow = null

    // Anti-echo guard for the `select_time_window`/`set_time_window`
    // round trip (F04 quality finding m1, `assets/js/lib/window_echo.js`).
    this.echoGuard = createEchoGuard()

    this.svg = select(this.el).append("svg").attr("class", "block h-full w-full")
    this.histogramLayer = this.svg.append("g").attr("class", "timeline-histogram")
    // Between the histogram and the axis (fixed here, issue #021: the
    // original #020 placement appended this layer last, which visually put
    // it *above* the axis labels despite this same comment already
    // documenting the intended "below axis labels" order; corrected as
    // part of building the window this layer exists for).
    this.windowLayer = this.svg.append("g").attr("class", "timeline-window")
    this.axisLayer = this.svg.append("g").attr("class", "timeline-axis")

    this.setupWindowLayer()

    this.debouncedRender = debounce(() => this.renderAndFetch(), RESIZE_DEBOUNCE_MS)
    this.debouncedPushWindow = debounce(() => this.pushWindow(), RESIZE_DEBOUNCE_MS)

    this.resizeObserver = new ResizeObserver(() => this.debouncedRender())
    this.resizeObserver.observe(this.el)

    this.onSchemeChange = () => this.render()
    this.darkScheme.addEventListener("change", this.onSchemeChange)

    this.onMotionChange = () => this.render()
    this.motionQuery.addEventListener("change", this.onMotionChange)

    // Pointer Events for the drag gesture are captured on the specific
    // handle/body element (`setPointerCapture`, attached per-element in
    // `setupWindowLayer`), but `pointermove`/`pointerup`/`pointercancel`
    // are listened for on `window`: pointer capture keeps delivering them
    // to the captured element even once the cursor leaves it, but the
    // *hook* still needs a single place to react regardless of which
    // element (a handle or the body) is being dragged.
    this.onPointerMove = event => this.handlePointerMove(event)
    this.onPointerUp = event => this.handlePointerEnd(event)
    window.addEventListener("pointermove", this.onPointerMove)
    window.addEventListener("pointerup", this.onPointerUp)
    window.addEventListener("pointercancel", this.onPointerUp)

    // Consumed by the LiveView Explore (#018): mirrors the map hook's own
    // `set_time_window` handler, keeping the two in lockstep. The
    // interactive drag (#021) pushes the *opposite* direction
    // (`select_time_window`, `pushWindow` below), debounced client-side
    // before it does.
    //
    // Anti-echo, hardened (F04 quality finding m1): a window received
    // while `this.drag` is active is absorbed by the gesture guard, and
    // the current local preview is re-broadcast so `MapHook` (which has
    // no drag guard of its own and just applied the server's window) does
    // not diverge from what this hook renders (F04 quality finding m2).
    // Outside a drag, `this.echoGuard` drops any stale echo from an
    // earlier push while a newer push is in flight (see
    // `assets/js/lib/window_echo.js`); an identical window is a no-op.
    // A window change never refetches the histogram (F04 decision D2:
    // the histogram covers the full domain, the window is only a brush).
    this.handleEvent("set_time_window", ({from, to}) => {
      if (this.drag) {
        this.redispatchPreview()
        return
      }

      if (!this.echoGuard.shouldApply({from, to})) return
      if (from === this.timeWindow.from && to === this.timeWindow.to) return

      this.timeWindow = {from, to}
      this.render()
    })

    this.renderAndFetch()
  },

  domain() {
    return {minYear: this.timeScale.minYear, maxYear: this.timeScale.maxYear}
  },

  // Creates the window's three DOM nodes once (body, then the two edge
  // handles, painted on top of the body so their hit area wins) and wires
  // every Pointer Events / keyboard listener onto them: `renderWindow`
  // below only ever updates attributes on these same persistent nodes,
  // it never recreates them, so listeners attached here stay valid for
  // the hook's whole lifetime.
  setupWindowLayer() {
    const gradientId = `${this.el.id}-time-gradient`

    const defs = this.windowLayer.append("defs")
    const gradient = defs
      .append("linearGradient")
      .attr("id", gradientId)
      .attr("x1", "0%")
      .attr("x2", "100%")
      .attr("y1", "0%")
      .attr("y2", "0%")
    this.gradientStartStop = gradient.append("stop").attr("offset", "0%")
    this.gradientEndStop = gradient.append("stop").attr("offset", "100%")

    this.bodyRect = this.windowLayer
      .append("rect")
      .attr("class", "timeline-window-body")
      .attr("fill", `url(#${gradientId})`)
      .attr("tabindex", "0")
      .attr("role", "group")
      .style("cursor", "grab")
      .style("touch-action", "none")

    this.handleFromRect = this.createHandle("from", this.i18n.windowStart)
    this.handleToRect = this.createHandle("to", this.i18n.windowEnd)

    this.bodyRect.node().addEventListener("pointerdown", event => {
      this.beginDrag(event, this.bodyRect.node(), {kind: "translate"})
    })
    this.bodyRect.node().addEventListener("keydown", event => this.handleBodyKeydown(event))
  },

  // `ariaLabel` (F04 quality finding m3) is the translated handle name
  // served through the `data-i18n-window-start`/`-end` attributes.
  createHandle(edge, ariaLabel) {
    const handle = this.windowLayer
      .append("rect")
      .attr("class", `timeline-window-handle timeline-window-handle-${edge}`)
      .attr("tabindex", "0")
      .attr("role", "slider")
      .attr("aria-orientation", "horizontal")
      .attr("aria-label", ariaLabel)
      .style("cursor", "ew-resize")
      .style("touch-action", "none")

    handle.node().addEventListener("pointerdown", event => {
      this.beginDrag(event, handle.node(), {kind: "resize", edge})
    })
    handle.node().addEventListener("keydown", event => this.handleHandleKeydown(edge, event))

    return handle
  },

  beginDrag(event, target, drag) {
    // Only the primary pointer's main button starts a gesture (F04
    // quality finding m4): a right/middle click or a second simultaneous
    // touch is ignored rather than starting (or racing) a drag.
    if (event.button !== 0 || !event.isPrimary) return
    if (this.drag) return

    event.preventDefault()
    // `preventDefault()` on `pointerdown` suppresses the browser's own
    // focus-on-click, so focus is given programmatically (F04 quality
    // finding m3): clicking a handle or the body makes it the keyboard
    // target, and the `:focus-visible` styles in `assets/css/app.css`
    // stay reachable without tabbing.
    if (typeof target.focus === "function") target.focus({preventScroll: true})
    target.setPointerCapture(event.pointerId)

    this.dragTarget = target
    this.drag = {
      ...drag,
      pointerId: event.pointerId,
      startClientX: event.clientX,
      startWindow: clampWindow(this.timeWindow, this.domain(), MIN_WINDOW_WIDTH_YEARS)
    }

    if (drag.kind === "translate") this.bodyRect.style("cursor", "grabbing")
  },

  handlePointerMove(event) {
    if (!this.drag || event.pointerId !== this.drag.pointerId) return
    if (!this.xScale) return

    const deltaPx = event.clientX - this.drag.startClientX
    this.timeWindow = this.windowForDrag(deltaPx)

    this.render()
    this.debouncedPushWindow()
  },

  // Converts a pixel delta (from `this.drag.startClientX`) into the
  // resized or translated window, through the exact same pixel <-> year
  // path `renderWindow`'s positions come from (`this.xScale`, `this.
  // timeScale`): dragging the boundary to a screen position and reading
  // that same position back always agree.
  windowForDrag(deltaPx) {
    const {kind, edge, startWindow} = this.drag

    if (kind === "resize") {
      const proposedYear = this.pixelDeltaToYear(startWindow[edge], deltaPx)
      return resizeEdge(startWindow, edge, proposedYear, this.domain(), MIN_WINDOW_WIDTH_YEARS)
    }

    const proposedYear = this.pixelDeltaToYear(startWindow.from, deltaPx)
    return translateWindow(startWindow, proposedYear - startWindow.from, this.domain())
  },

  pixelDeltaToYear(baseYear, deltaPx) {
    const basePx = this.xScale(this.timeScale.position(baseYear))
    return this.timeScale.year(this.xScale.invert(basePx + deltaPx))
  },

  handlePointerEnd(event) {
    if (!this.drag || event.pointerId !== this.drag.pointerId) return

    if (this.dragTarget && this.dragTarget.hasPointerCapture(event.pointerId)) {
      this.dragTarget.releasePointerCapture(event.pointerId)
    }

    this.bodyRect.style("cursor", "grab")
    this.drag = null
    this.dragTarget = null

    // Flushed immediately, not left to the debounce (issue #021: "[le
    // pushEvent est] systématiquement [déclenché] au pointerup"), so
    // releasing the handle never waits out the remainder of a debounce
    // window that happened to still be running.
    this.debouncedPushWindow.cancel()
    this.pushWindow()
  },

  // WAI-ARIA slider keyboard support on each handle (F04 quality finding
  // m3): arrows nudge by the window-local graduation step (Shift for x10),
  // Home/End send the edge to the domain bound on its side
  // (`resizeEdge` clamps the opposite side to `minWidth`, so Home on the
  // right handle stops at `from + minWidth`, as the slider pattern
  // expects for its minimum).
  handleHandleKeydown(edge, event) {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return
    event.preventDefault()

    const domain = this.domain()
    const startWindow = clampWindow(this.timeWindow, domain, MIN_WINDOW_WIDTH_YEARS)
    const proposedYear = this.proposedHandleYear(edge, event, startWindow, domain)

    this.timeWindow = resizeEdge(startWindow, edge, proposedYear, domain, MIN_WINDOW_WIDTH_YEARS)
    this.render()
    this.debouncedPushWindow()
  },

  proposedHandleYear(edge, event, startWindow, domain) {
    if (event.key === "Home") return domain.minYear
    if (event.key === "End") return domain.maxYear

    const direction = event.key === "ArrowRight" ? 1 : -1
    return startWindow[edge] + direction * this.keyboardStepYears(event)
  },

  // Body keyboard support: arrows translate the whole window (width
  // preserved), Home/End slide it flush against the domain's start/end
  // (F04 quality finding m3).
  handleBodyKeydown(event) {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return
    event.preventDefault()

    const domain = this.domain()
    const startWindow = clampWindow(this.timeWindow, domain, MIN_WINDOW_WIDTH_YEARS)

    this.timeWindow = translateWindow(
      startWindow,
      this.bodyKeyDelta(event, startWindow, domain),
      domain
    )
    this.render()
    this.debouncedPushWindow()
  },

  bodyKeyDelta(event, startWindow, domain) {
    if (event.key === "Home") return domain.minYear - startWindow.from
    if (event.key === "End") return domain.maxYear - startWindow.to

    const direction = event.key === "ArrowRight" ? 1 : -1
    return direction * this.keyboardStepYears(event)
  },

  // Shift+arrow moves by 10 steps at once (issue #021), plain arrow by
  // one `windowStepYears()` (the graduation step the *window's own span*
  // would produce, not the static full-domain axis step of decision D2:
  // the nudge must stay proportionate to what the user is looking at,
  // and a full-domain graduation would jump tens of millennia at once).
  keyboardStepYears(event) {
    return (event.shiftKey ? 10 : 1) * this.windowStepYears()
  },

  // The "typical" tick step of the current window at the current width:
  // the same tick machinery the axis used before D2 made the axis static,
  // now computed on demand for the keyboard nudge and the handles'
  // `aria-valuetext` granularity. The middle tick's own step reads as
  // "typical" better than the first (which, per `tickSteps`'s own doc, is
  // measured against the *second* tick rather than a true predecessor).
  windowStepYears() {
    const {width} = this.dimensions()
    const ticks = this.timeScale.ticks(
      this.timeWindow.from,
      this.timeWindow.to,
      this.tickCount(width)
    )
    const steps = tickSteps(ticks)

    return steps.length > 0 ? steps[Math.floor(steps.length / 2)] : 1
  },

  // Pushes the current window to the server, debounced during a drag
  // (`this.debouncedPushWindow`) and immediately on `pointerup`/a keyboard
  // nudge's own debounce tick. Named `select_time_window`
  // (`.claude/rules/liveview.md`'s own example event name), deliberately
  // distinct from `set_time_window`: that name is the server -> client
  // push shared with the map hook (issue #018), this one is the
  // client -> server intent; reusing one name for both directions is
  // exactly the ambiguity this issue's own contract exists to resolve.
  // The push is recorded on `this.echoGuard` first, so the eventual
  // server echo is recognized and any stale echo from an earlier push is
  // dropped (F04 quality finding m1).
  pushWindow() {
    this.echoGuard.recordPush(this.timeWindow)
    this.pushEvent("select_time_window", {from: this.timeWindow.from, to: this.timeWindow.to})
  },

  // Broadcasts the current window for `MapHook` to preview immediately
  // (issue #022, `TIME_WINDOW_PREVIEW_EVENT`): purely a same-tab DOM
  // event, never routed through the LiveView, so it carries no server
  // round trip and triggers no data refetch.
  dispatchPreview() {
    if (
      this.lastDispatchedWindow &&
      this.lastDispatchedWindow.from === this.timeWindow.from &&
      this.lastDispatchedWindow.to === this.timeWindow.to
    ) {
      return
    }

    this.lastDispatchedWindow = {...this.timeWindow}
    window.dispatchEvent(
      new CustomEvent(TIME_WINDOW_PREVIEW_EVENT, {detail: {...this.timeWindow}})
    )
  },

  // Re-broadcasts the current preview even if unchanged (F04 quality
  // finding m2): used when a server `set_time_window` was absorbed by the
  // active-drag guard, since `MapHook` has no such guard and just applied
  // the server's (older) window to its gradient; without this rebroadcast
  // the two hooks would render different windows until the next pointer
  // movement.
  redispatchPreview() {
    this.lastDispatchedWindow = null
    this.dispatchPreview()
  },

  dimensions() {
    const rect = this.el.getBoundingClientRect()
    return {width: Math.max(rect.width, 0), height: Math.max(rect.height, 0)}
  },

  tickCount(width) {
    const innerWidth = Math.max(width - MARGIN.left - MARGIN.right, 0)
    return Math.max(Math.round(innerWidth / PIXELS_PER_TICK), MIN_TICK_COUNT)
  },

  // Renders, then refetches the histogram only if the rendered width now
  // calls for a different bucket count (F04 decision D2): the axis and
  // window render immediately and never wait on the network.
  renderAndFetch() {
    this.render()
    this.maybeFetchHistogram()
  },

  render() {
    const {width, height} = this.dimensions()
    if (width === 0 || height === 0) return

    const tokens = readDesignTokens()
    const reducedMotion = this.motionQuery.matches

    this.svg.attr("viewBox", `0 0 ${width} ${height}`)

    const axisHeight = height * (1 - HISTOGRAM_HEIGHT_RATIO)
    const histogramHeight = height - axisHeight - MARGIN.bottom

    const xScale = scaleLinear()
      .domain([0, 1])
      .range([MARGIN.left, width - MARGIN.right])
    // Kept for the drag gesture's pixel <-> year conversions
    // (`pixelDeltaToYear`): the same scale instance the visuals below are
    // positioned with, so a drag and its own rendering never disagree.
    this.xScale = xScale

    this.renderHistogram(xScale, histogramHeight, tokens, reducedMotion)
    this.renderAxis(xScale, histogramHeight, tokens)
    this.renderWindow(xScale, height, tokens, reducedMotion)
    this.dispatchPreview()
  },

  // The axis is graduated over the FULL domain, independent of the current
  // window (F04 decision D2): the frise is a static background the window
  // brushes over, so its graduations never re-layout during a drag.
  renderAxis(xScale, top, tokens) {
    const {width} = this.dimensions()
    const {minYear, maxYear} = this.domain()
    const count = this.tickCount(width)
    const ticks = this.timeScale.ticks(minYear, maxYear, count)
    // The step passed to `formatAxisYear` for each tick is its distance to
    // the *previous* tick (or to the next one for the very first): the
    // full domain straddles the BP threshold and merges two regimes
    // (`Amanogawa.Atlas.TimeScale.ticks/3`'s own moduledoc), so a single
    // domain-wide step would mislabel one side of the merge.
    const steps = tickSteps(ticks)

    const axis = axisBottom(xScale)
      .tickValues(ticks.map(year => this.timeScale.position(year)))
      .tickFormat((_position, index) =>
        formatAxisYear(ticks[index], steps[index], this.i18n.templates)
      )
      .tickSizeOuter(0)

    this.axisLayer.attr("transform", `translate(0, ${top})`).call(axis)

    this.axisLayer.select(".domain").attr("stroke", tokens.borderColor)
    this.axisLayer.selectAll(".tick line").attr("stroke", tokens.borderColor)
    this.axisLayer
      .selectAll(".tick text")
      .attr("fill", tokens.mutedColor)
      .attr("font-size", "0.6875rem")
  },

  // Bars, not a smooth area (issue #020 leaves the choice to the
  // implementation): with buckets often only a few pixels wide near the
  // present edge of the symlog domain, discrete bars read unambiguously as
  // "one bucket, one count", whereas a smoothed area would visually imply
  // interpolation between buckets that never happened. Bar height is
  // linear in count (`scaleSqrt` was considered per the issue's own
  // suggestion, but the corpus's right-skewed importance/density
  // distribution made a sqrt scale flatten genuinely quiet eras into
  // visually identical bars; documented here since the choice is a
  // judgment call, not a hard requirement).
  renderHistogram(xScale, height, tokens, reducedMotion) {
    const buckets = this.histogram ? this.histogram.buckets : []
    const maxCount = Math.max(1, ...buckets.map(bucket => bucket.count))

    const yScale = scaleLinear().domain([0, maxCount]).range([0, height])

    const bars = this.histogramLayer.selectAll("rect").data(buckets, bucket => bucket.from)

    bars.exit().remove()

    const merged = bars
      .enter()
      .append("rect")
      .merge(bars)
      .attr("x", bucket => xScale(this.timeScale.position(bucket.from)))
      .attr(
        "width",
        bucket =>
          Math.max(xScale(this.timeScale.position(bucket.to)) - xScale(this.timeScale.position(bucket.from)) - 1, 0)
      )
      .attr("y", bucket => height - yScale(bucket.count))
      .attr("height", bucket => yScale(bucket.count))
      .attr("fill", tokens.accentColor)

    merged.style("transition", reducedMotion ? "none" : "height 150ms ease, y 150ms ease")
  },

  // Positions the window body and its two edge handles, tints the body
  // with the shared temporal gradient (issue #022, the exact same
  // `colorFor`/tokens `MapHook` and `TimeLegend` use), and keeps every
  // ARIA slider attribute (WAI-ARIA slider pattern) in sync with the
  // current window. No animation while a gesture is in progress
  // (`this.drag`): a CSS transition racing 60fps pointer updates would lag
  // behind the cursor instead of tracking it.
  renderWindow(xScale, height, tokens, reducedMotion) {
    const {from, to} = this.timeWindow
    const fromX = xScale(this.timeScale.position(from))
    const toX = xScale(this.timeScale.position(to))
    const left = Math.min(fromX, toX)
    const width = Math.max(Math.abs(toX - fromX), 0)
    const handleHeight = Math.max(height, HANDLE_MIN_HIT_HEIGHT_PX)
    const stepYears = this.windowStepYears()

    this.gradientStartStop.attr("stop-color", colorFor(0, tokens.gradientTokens))
    this.gradientEndStop.attr("stop-color", colorFor(1, tokens.gradientTokens))

    const animated = !reducedMotion && !this.drag
    const transition = animated ? "x 150ms ease, width 150ms ease" : "none"

    this.bodyRect
      .attr("x", left)
      .attr("y", 0)
      .attr("width", width)
      .attr("height", height)
      .attr(
        "aria-label",
        `${this.formatYear(from, stepYears)} - ${this.formatYear(to, stepYears)}`
      )
      .style("opacity", WINDOW_FILL_OPACITY)
      .style("transition", transition)

    this.positionHandle(this.handleFromRect, fromX, handleHeight, {
      value: from,
      min: this.timeScale.minYear,
      max: to,
      stepYears,
      transition
    })
    this.positionHandle(this.handleToRect, toX, handleHeight, {
      value: to,
      min: from,
      max: this.timeScale.maxYear,
      stepYears,
      transition
    })
  },

  positionHandle(handle, centerX, height, {value, min, max, stepYears, transition}) {
    handle
      .attr("x", centerX - HANDLE_HIT_WIDTH_PX / 2)
      .attr("y", 0)
      .attr("width", HANDLE_HIT_WIDTH_PX)
      .attr("height", height)
      .attr("aria-valuemin", min)
      .attr("aria-valuemax", max)
      .attr("aria-valuenow", value)
      .attr("aria-valuetext", this.formatYear(value, stepYears))
      .style("transition", transition)
  },

  formatYear(year, stepYears) {
    return formatAxisYear(year, stepYears, this.i18n.templates)
  },

  // Fetches the full-domain histogram (F04 decision D2), but only when
  // the bucket count worth drawing actually changed (the first render,
  // then a significant resize): a drag or a window change never lands
  // here.
  maybeFetchHistogram() {
    const {width} = this.dimensions()
    if (width === 0) return

    const buckets = histogramBucketCount(width)
    if (buckets === this.lastFetchedBuckets) return

    this.lastFetchedBuckets = buckets
    this.fetchHistogram(buckets)
  },

  async fetchHistogram(buckets) {
    if (this.abortController) this.abortController.abort()

    const controller = new AbortController()
    this.abortController = controller

    // Defensive clamp (F04 correction M1): the request is built from the
    // domain itself, so it is in bounds by construction, but the clamp
    // guarantees that no future caller (or misconfigured scale) can ever
    // send `GET /api/events/histogram` a window the server would 422.
    const {from, to} = clampWindow(
      {from: this.timeScale.minYear, to: this.timeScale.maxYear},
      this.domain(),
      MIN_WINDOW_WIDTH_YEARS
    )

    const params = new URLSearchParams({
      from: String(from),
      to: String(to),
      buckets: String(buckets)
    })

    try {
      const response = await fetch(`/api/events/histogram?${params}`, {signal: controller.signal})

      if (!response.ok) {
        throw new Error(`histogram request failed with status ${response.status}`)
      }

      this.histogram = await response.json()
      this.render()
      // The one DOM signal the E2E suite (issue #029) synchronizes on
      // before asserting on histogram bars: harmless in every environment,
      // carries no information beyond "the histogram fetched at least
      // once".
      this.el.setAttribute("data-histogram-loaded", "true")
    } catch (error) {
      if (error.name === "AbortError") return

      // Allow a later resize (or reconnect-triggered remount) to retry
      // instead of pinning the failed bucket count as "already fetched".
      if (this.lastFetchedBuckets === buckets) this.lastFetchedBuckets = null

      if (process.env.NODE_ENV !== "production") {
        console.error("TimelineHook: failed to fetch histogram", error)
      }
    }
  },

  destroyed() {
    this.debouncedRender.cancel()
    this.debouncedPushWindow.cancel()
    this.resizeObserver.disconnect()
    if (this.abortController) this.abortController.abort()
    this.echoGuard.dispose()

    this.darkScheme.removeEventListener("change", this.onSchemeChange)
    this.motionQuery.removeEventListener("change", this.onMotionChange)

    // Pointer Events and keyboard listeners added in `setupWindowLayer`
    // (issue #021): the per-handle/body `pointerdown`/`keydown` listeners
    // are discarded along with their nodes by `replaceChildren()` below,
    // but the `window`-level `pointermove`/`pointerup`/`pointercancel`
    // listeners are not attached to anything inside `this.el` and must be
    // removed explicitly.
    window.removeEventListener("pointermove", this.onPointerMove)
    window.removeEventListener("pointerup", this.onPointerUp)
    window.removeEventListener("pointercancel", this.onPointerUp)

    this.el.replaceChildren()
  }
}

function parseYear(value, fallback) {
  const parsed = Number.parseInt(value, 10)
  return Number.isFinite(parsed) ? parsed : fallback
}

// Per-tick step (the distance to the previous tick, or to the next one for
// the first), used as `formatAxisYear`'s granularity hint: exported for
// `assets/js/test/timeline_tick_steps.test.js` since it is the one piece
// of tick-label logic this hook owns outside of `time_scale.js`/
// `time_format.js`. Falls back to `1` (the finest regime) for a
// degenerate single-tick (or empty) set.
export function tickSteps(ticks) {
  if (ticks.length <= 1) return ticks.map(() => 1)

  return ticks.map((year, index) => {
    const neighbor = index === 0 ? ticks[1] : ticks[index - 1]
    return Math.abs(year - neighbor)
  })
}

export default TimelineHook
