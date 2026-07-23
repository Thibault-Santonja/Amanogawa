// LiveView hook rendering the timeline strip in the layout's
// `footer#timeline` (issue #020): a symlog-graduated axis (d3-axis over
// `assets/js/lib/time_scale.js`'s pure position math) and, below it, a
// density histogram fetched from `GET /api/events/histogram`.
//
// State (the current time window) is owned by the LiveView (ADR 0005,
// issue #018), pushed here the same way it reaches the map hook
// (`set_time_window`, `assets/js/hooks/map_hook.js`). This issue renders
// the window as data only (`data-from`/`data-to`); the interactive drag
// rectangle is issue #021, which reuses the dedicated `window` SVG layer
// already set up below so its own rendering slots in without touching the
// axis/histogram layers.
//
// Volumes (the histogram counts) never go through LiveView diffs
// (`.claude/rules/liveview.md`): this hook fetches its own data and holds
// it only for the duration of a render, exactly like the map hook's event
// GeoJSON.
import {axisBottom} from "d3-axis"
import {scaleLinear, scaleSqrt} from "d3-scale"
import {select} from "d3-selection"

import {formatAxisYear} from "../lib/time_format.js"
import {createTimeScale} from "../lib/time_scale.js"

// Roughly one graduation per this many pixels of axis width, per issue
// #020 ("nombre de graduations cible proportionnel à la largeur").
const PIXELS_PER_TICK = 80
const MIN_TICK_COUNT = 2

const MARGIN = {top: 8, right: 16, bottom: 20, left: 16}
const HISTOGRAM_HEIGHT_RATIO = 0.55

// Time between the last `ResizeObserver` callback and the next render, and
// between successive histogram fetches triggered by the same burst of
// resizes: matches the map hook's own debounce constant
// (`.claude/rules/liveview.md`: debounce before a data refetch).
const RESIZE_DEBOUNCE_MS = 150

const HISTOGRAM_BUCKETS = 100

function readDesignTokens() {
  const rootStyle = getComputedStyle(document.documentElement)

  return {
    textColor: rootStyle.getPropertyValue("--palette-text").trim(),
    mutedColor: rootStyle.getPropertyValue("--palette-text-muted").trim(),
    borderColor: rootStyle.getPropertyValue("--palette-border").trim(),
    accentColor: rootStyle.getPropertyValue("--palette-accent").trim()
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

const TimelineHook = {
  mounted() {
    this.timeScale = createTimeScale()
    this.timeWindow = {
      from: parseYear(this.el.dataset.from, this.timeScale.minYear),
      to: parseYear(this.el.dataset.to, this.timeScale.maxYear)
    }

    this.motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)")
    this.darkScheme = window.matchMedia("(prefers-color-scheme: dark)")

    this.abortController = null
    this.histogram = null

    this.svg = select(this.el).append("svg").attr("class", "block h-full w-full")
    this.histogramLayer = this.svg.append("g").attr("class", "timeline-histogram")
    this.axisLayer = this.svg.append("g").attr("class", "timeline-axis")
    // Reserved for issue #021's draggable window rectangle: created now so
    // the rendering order (window above histogram, below axis labels) is
    // right from the start and #021 never has to reshuffle layers.
    this.windowLayer = this.svg.append("g").attr("class", "timeline-window")

    this.debouncedRender = debounce(() => this.renderAndFetch(), RESIZE_DEBOUNCE_MS)

    this.resizeObserver = new ResizeObserver(() => this.debouncedRender())
    this.resizeObserver.observe(this.el)

    this.onSchemeChange = () => this.render()
    this.darkScheme.addEventListener("change", this.onSchemeChange)

    this.onMotionChange = () => this.render()
    this.motionQuery.addEventListener("change", this.onMotionChange)

    // Consumed by the LiveView Explore (#018): mirrors the map hook's own
    // `set_time_window` handler, keeping the two in lockstep. The
    // interactive drag (#021) will push the *opposite* direction
    // (`select_time_window`), debounced client-side before it does.
    this.handleEvent("set_time_window", ({from, to}) => {
      if (from === this.timeWindow.from && to === this.timeWindow.to) return

      this.timeWindow = {from, to}
      this.renderAndFetch()
    })

    this.renderAndFetch()
  },

  dimensions() {
    const rect = this.el.getBoundingClientRect()
    return {width: Math.max(rect.width, 0), height: Math.max(rect.height, 0)}
  },

  tickCount(width) {
    const innerWidth = Math.max(width - MARGIN.left - MARGIN.right, 0)
    return Math.max(Math.round(innerWidth / PIXELS_PER_TICK), MIN_TICK_COUNT)
  },

  // Fetches the histogram for the current window and re-renders once it
  // resolves; the axis itself renders immediately (it needs no network
  // round-trip), so the graduations never wait on the histogram fetch.
  renderAndFetch() {
    this.render()
    this.fetchHistogram()
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

    this.renderHistogram(xScale, histogramHeight, tokens, reducedMotion)
    this.renderAxis(xScale, histogramHeight, tokens)
  },

  renderAxis(xScale, top, tokens) {
    const {width} = this.dimensions()
    const {from, to} = this.timeWindow
    const count = this.tickCount(width)
    const ticks = this.timeScale.ticks(from, to, count)
    // The step passed to `formatAxisYear` for each tick is its distance to
    // the *previous* tick (or to the next one for the very first): a
    // window straddling the BP threshold merges two different regimes
    // (`Amanogawa.Atlas.TimeScale.ticks/3`'s own moduledoc), so a single
    // window-wide step would mislabel one side of the merge.
    const steps = tickSteps(ticks)

    const axis = axisBottom(xScale)
      .tickValues(ticks.map(year => this.timeScale.position(year)))
      .tickFormat((_position, index) => formatAxisYear(ticks[index], steps[index]))
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

  async fetchHistogram() {
    if (this.abortController) this.abortController.abort()

    const controller = new AbortController()
    this.abortController = controller

    const {from, to} = this.timeWindow
    const params = new URLSearchParams({
      from: String(from),
      to: String(to),
      buckets: String(HISTOGRAM_BUCKETS)
    })

    try {
      const response = await fetch(`/api/events/histogram?${params}`, {signal: controller.signal})

      if (!response.ok) {
        throw new Error(`histogram request failed with status ${response.status}`)
      }

      this.histogram = await response.json()
      this.render()
    } catch (error) {
      if (error.name === "AbortError") return

      if (process.env.NODE_ENV !== "production") {
        console.error("TimelineHook: failed to fetch histogram", error)
      }
    }
  },

  destroyed() {
    this.debouncedRender.cancel()
    this.resizeObserver.disconnect()
    if (this.abortController) this.abortController.abort()

    this.darkScheme.removeEventListener("change", this.onSchemeChange)
    this.motionQuery.removeEventListener("change", this.onMotionChange)

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
