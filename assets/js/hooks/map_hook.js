// LiveView hook owning the MapLibre map instance.
//
// Renders the world basemap (light or dark variant following the system
// theme, #005), the historical events layer (#015: a GeoJSON source
// fetched from `GET /api/events`, styled by data-driven expressions in
// `assets/js/map/event_layers.js`, refetched as the viewport or the time
// window changes), the hover card and click-to-select event panel (#016),
// and the relation lines traced around the selected event (#017). State
// (the time window, the map view, the selection) is owned by the LiveView
// (ADR 0005, issue #018): this hook only renders and reports lightweight
// intents (`map_moved`, `select_event`, `deselect_event`), it never holds
// the event list or the selected event's data outside the MapLibre
// sources and its own small hover/link caches.
//
// The vendored styles (assets/vendor/map-styles/) are bundled into app.js:
// only tiles, glyphs, sprites, and Wikipedia thumbnails (issue #016) are
// fetched from origins allowed by the Content-Security-Policy.
import maplibregl from "maplibre-gl"

import {boundsToBbox, normalizedMapMovedPayload} from "../map/bbox.js"
import {debounce} from "../map/debounce.js"
import {
  EVENTS_CIRCLE_LAYER_ID,
  EVENTS_LABEL_LAYER_ID,
  EVENTS_SOURCE_ID,
  VISIBLE_OPACITY,
  eventsCircleLayer,
  eventsLabelLayer,
  eventsSource,
  textOpacityExpression,
  windowedOpacityExpression
} from "../map/event_layers.js"
import {createHoverCard} from "../map/hover_card.js"
import {fadeTransition} from "../map/style_utils.js"
import {
  HIDDEN_OPACITY as LINKS_HIDDEN_OPACITY,
  LINKS_LAYER_ID,
  LINKS_SOURCE_ID,
  VISIBLE_OPACITY as LINKS_VISIBLE_OPACITY,
  emptyFeatureCollection as emptyLinksFeatureCollection,
  linksLineLayer,
  linksSource
} from "../map/link_layers.js"
import {TIME_WINDOW_PREVIEW_EVENT, mapLibreColorExpression, readGradientTokens} from "../lib/time_gradient.js"
import darkStyle from "../../vendor/map-styles/dark.json"
import lightStyle from "../../vendor/map-styles/light.json"

const INITIAL_CENTER = [0, 20]
const INITIAL_ZOOM = 1.5

// Time between the last `moveend`/`zoomend` and the events refetch, and
// between the last `moveend` and the `map_moved` intent pushed to the
// LiveView (`.claude/rules/liveview.md`: debounce client intents).
const FETCH_DEBOUNCE_MS = 250
const MAP_MOVED_DEBOUNCE_MS = 250

// Duration of the programmatic camera move triggered by a server-pushed
// `set_view` (skipped entirely, via `jumpTo`, under reduced motion).
const SET_VIEW_EASE_DURATION_MS = 500

// Tolerances `matchesCurrentView` uses to skip a server-pushed `set_view`
// that already matches the camera (issue security-review #2): zoom is a
// single float with comparatively coarse practical resolution, lat/lng
// need a much tighter tolerance since a real, meaningfully different
// coordinate can differ by a tiny fraction of a degree.
const ZOOM_EPSILON = 1e-3
const COORDINATE_EPSILON = 1e-6

// Delay (issue #016) between a marker being hovered and the hover card
// appearing: a single timer, reärmed on every newly hovered feature, not a
// separate fetch debounce. It doubles as an anti-burst guard, so a cursor
// merely passing over a marker never triggers a summary fetch.
const HOVER_DELAY_MS = 150

// Reads the palette tokens the events and event-links layers are styled
// with (`assets/css/app.css`): never a hardcoded hex value when a token
// exists. `gradientTokens` (issue #022) is read through the shared
// `readGradientTokens` (`assets/js/lib/time_gradient.js`), the same
// function `TimelineHook` and `AmanogawaWeb.Components.TimeLegend`'s CSS
// ultimately derive from: never re-parsed or hardcoded here.
function readDesignTokens() {
  const rootStyle = getComputedStyle(document.documentElement)

  return {
    accentColor: rootStyle.getPropertyValue("--palette-accent").trim(),
    haloColor: rootStyle.getPropertyValue("--palette-surface").trim(),
    textColor: rootStyle.getPropertyValue("--palette-text").trim(),
    gradientTokens: readGradientTokens(document.documentElement),
    linkColors: {
      part_of: rootStyle.getPropertyValue("--palette-link-part-of").trim(),
      follows: rootStyle.getPropertyValue("--palette-link-follows").trim(),
      cause: rootStyle.getPropertyValue("--palette-link-cause").trim(),
      effect: rootStyle.getPropertyValue("--palette-link-effect").trim(),
      significant: rootStyle.getPropertyValue("--palette-link-significant").trim(),
      default: rootStyle.getPropertyValue("--palette-link-default").trim()
    }
  }
}

const MapHook = {
  mounted() {
    this.darkScheme = window.matchMedia("(prefers-color-scheme: dark)")
    this.motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)")
    // Read once at mount, kept in sync through the listener below: not
    // re-evaluated on every frame or every animation.
    this.reducedMotion = this.motionQuery.matches

    this.timeWindow = {from: null, to: null}
    // The window used for the temporal gradient's color/opacity (issue
    // #022): normally identical to `this.timeWindow`, but updated
    // immediately (no debounce, no refetch) from `TimelineHook`'s local
    // drag preview (`onWindowPreview` below) so the map recolors in real
    // time while the user drags, ahead of the server round trip that
    // eventually updates `this.timeWindow` and triggers `fetchEvents`.
    this.previewWindow = {from: null, to: null}
    this.abortController = null
    this.eventsLoadedOnce = false
    // Monotonic counter of successful `setEventsData` calls, rendered as
    // `data-events-fetch-count` (issue #029): unlike the `data-events-
    // loaded` flag below, a count lets the E2E dark-mode scenario detect
    // that a *new* fetch landed after a theme change (`onStyleLoad`
    // re-running `fetchEvents`) rather than merely that the flag was
    // already `"true"` from the very first load.
    this.eventsFetchCount = 0
    this.selectedQid = null
    // Marks a camera move triggered by `setView` (server-pushed), so the
    // `moveend` it causes is not mistaken for a user-driven move and
    // echoed back to the server as `map_moved` (issue #018 anti-loop
    // guard).
    this.programmaticMove = false

    // Hover card state (issue #016): `hoveringQid` is the feature currently
    // under the cursor (or `null`), `hoverTimer` the single reärmed timer
    // behind `HOVER_DELAY_MS`, `hoverSummaryCache` a client-side cache by
    // qid so hovering the same marker twice never refetches, and
    // `hoverAbortController` the in-flight summary fetch, if any.
    this.hoveringQid = null
    this.hoverTimer = null
    this.hoverSummaryCache = new Map()
    this.hoverAbortController = null
    this.hoverCard = createHoverCard(this.el)
    // Latest known cursor point over a marker, kept fresh on every
    // `mousemove` (see `onMarkerMove`) so a delayed `showHoverCard` (fired
    // `HOVER_DELAY_MS` after the point that armed it) still renders at the
    // cursor's current position, not a stale one.
    this.lastHoverPoint = null

    // Event-links state (issue #017): `linksAbortController` the in-flight
    // links fetch, `linksOpacityFrame` the pending `requestAnimationFrame`
    // that raises `line-opacity` after a fresh `setData`, cancelled on
    // `destroyed()` so it never runs against a torn-down map.
    this.linksAbortController = null
    this.linksOpacityFrame = null

    this.map = new maplibregl.Map({
      container: this.el,
      style: this.darkScheme.matches ? darkStyle : lightStyle,
      center: INITIAL_CENTER,
      zoom: INITIAL_ZOOM,
      attributionControl: {compact: true},
      // MapLibre already skips camera easing when the user prefers reduced
      // motion; also disable symbol fade-in so labels appear instantly.
      fadeDuration: this.reducedMotion ? 0 : 300
    })

    this.debouncedFetchEvents = debounce(() => this.fetchEvents(), FETCH_DEBOUNCE_MS)
    this.debouncedPushMapMoved = debounce(() => this.pushMapMoved(), MAP_MOVED_DEBOUNCE_MS)

    // `style.load` fires once for the initial style and again every time
    // `setStyle` completes (theme change): the events source and layers
    // are re-added here each time, since a style swap discards them, and
    // the data is refetched rather than cached (this hook never stores the
    // event list outside the MapLibre source, issue #015 point d'attention).
    this.onStyleLoad = () => {
      this.setupEventsLayer()
      this.setupLinksLayer()
      this.eventsLoadedOnce = false
      // Cleared while the style reloads (theme change) and re-set by
      // `setEventsData` once the refetch lands: the one DOM signal the E2E
      // suite (issue #029) synchronizes on before asserting anything about
      // rendered markers, since the WebGL canvas itself is not assertable.
      // Harmless in every environment, not gated like `data-e2e-test-api`
      // below: it carries no information beyond "events are up to date".
      this.el.removeAttribute("data-events-loaded")
      this.fetchEvents()
    }
    this.map.on("style.load", this.onStyleLoad)

    this.onMoveEnd = () => {
      this.debouncedFetchEvents()

      if (this.programmaticMove) {
        this.programmaticMove = false
        return
      }

      this.debouncedPushMapMoved()
    }
    this.map.on("moveend", this.onMoveEnd)

    this.onZoomEnd = () => this.debouncedFetchEvents()
    this.map.on("zoomend", this.onZoomEnd)

    // Selection contract (issue #018): clicking a marker selects it,
    // clicking empty map deselects. `event_selected`/`event_deselected`
    // pushed back by the LiveView drive the stroke highlight (below), the
    // relation lines (#017), and clear any lingering hover card.
    this.onMarkerClick = event => {
      const feature = event.features && event.features[0]
      if (!feature) return

      this.clearHoverState()
      this.pushEvent("select_event", {qid: feature.properties.qid})
    }
    this.map.on("click", EVENTS_CIRCLE_LAYER_ID, this.onMarkerClick)

    this.onMapClick = event => {
      const features = this.map.queryRenderedFeatures(event.point, {
        layers: [EVENTS_CIRCLE_LAYER_ID]
      })

      if (features.length === 0) this.pushEvent("deselect_event", {})
    }
    this.map.on("click", this.onMapClick)

    this.onMarkerEnter = () => {
      this.map.getCanvas().style.cursor = "pointer"
    }
    this.map.on("mouseenter", EVENTS_CIRCLE_LAYER_ID, this.onMarkerEnter)

    // Hover card (issue #016): repositions on every pixel of movement over
    // a marker, but only (re)arms the `HOVER_DELAY_MS` timer when the
    // hovered feature actually changes, so dragging the cursor across a
    // single large marker does not restart the delay on every frame.
    this.onMarkerMove = event => {
      const feature = event.features && event.features[0]
      if (!feature) return

      const qid = feature.properties.qid
      this.lastHoverPoint = event.point
      this.hoverCard.reposition(event.point)

      if (qid === this.hoveringQid) return

      this.hoveringQid = qid
      this.hoverCard.hide()
      this.clearHoverTimer()

      this.hoverTimer = setTimeout(() => {
        this.hoverTimer = null
        this.showHoverCard(qid, this.lastHoverPoint)
      }, HOVER_DELAY_MS)
    }
    this.map.on("mousemove", EVENTS_CIRCLE_LAYER_ID, this.onMarkerMove)

    this.onMarkerLeave = () => {
      this.map.getCanvas().style.cursor = ""
      this.clearHoverState()
    }
    this.map.on("mouseleave", EVENTS_CIRCLE_LAYER_ID, this.onMarkerLeave)

    // setStyle reloads the whole style; re-adding sources and layers after
    // a theme change is handled by `onStyleLoad` above.
    this.onSchemeChange = event => {
      this.map.setStyle(event.matches ? darkStyle : lightStyle)
    }
    this.darkScheme.addEventListener("change", this.onSchemeChange)

    // Applied immediately, not deferred to the next `style.load` (theme
    // change or reload): a `prefers-reduced-motion` change should take
    // effect on the very next fade, not require the user to also flip
    // their OS theme first (issue security-review #13).
    this.onMotionChange = event => {
      this.reducedMotion = event.matches
      this.applyMotionPreference()
    }
    this.motionQuery.addEventListener("change", this.onMotionChange)

    // Consumed by the LiveView Explore (#018): a fresh time window pushed
    // from the server always triggers an immediate refetch (not debounced,
    // the client-side drag on the future timeline hook already debounces
    // before pushing). Skipped when `from`/`to` are identical to the
    // window already applied: `handle_params/3` still pushes this event
    // whenever a URL patch touches state it did not cause (a pure
    // selection change, browser back/forward replaying the same window),
    // and re-fetching identical data on every such patch is wasted work
    // (issue security-review #2).
    this.handleEvent("set_time_window", ({from, to}) => {
      // The committed window always also becomes the preview window: a
      // server-pushed window (URL navigation, shared link) is authoritative
      // and must recolor the map even if no drag preview ever fired for
      // it (`TimelineHook` may not even be mounted yet on first load).
      this.previewWindow = {from, to}
      this.updateGradientPaint()

      if (from === this.timeWindow.from && to === this.timeWindow.to) return

      this.timeWindow = {from, to}
      this.fetchEvents()
    })

    // Consumed from `TimelineHook`'s local drag rendering (issue #022,
    // `assets/js/lib/time_gradient.js`'s `TIME_WINDOW_PREVIEW_EVENT`): a
    // pure style update (`setPaintProperty`), never a data refetch, so it
    // stays free during a drag that has not yet crossed the 150ms debounce
    // (`.claude/rules/liveview.md`).
    this.onWindowPreview = event => {
      // Defense in depth: this is a plain DOM CustomEvent any same-page
      // script could dispatch, so a malformed detail is dropped rather
      // than poisoning the MapLibre paint expressions with NaN/Infinity.
      if (
        !event.detail ||
        !Number.isFinite(event.detail.from) ||
        !Number.isFinite(event.detail.to)
      ) {
        return
      }

      const {from, to} = event.detail
      if (from === this.previewWindow.from && to === this.previewWindow.to) return

      this.previewWindow = {from, to}
      this.updateGradientPaint()
    }
    window.addEventListener(TIME_WINDOW_PREVIEW_EVENT, this.onWindowPreview)

    // Consumed by the LiveView Explore (#018): a server-pushed camera move
    // (URL navigation, shared link). Flagged as programmatic so the
    // resulting `moveend` is not echoed back as `map_moved`. Skipped when
    // `z`/`lat`/`lng` already match the current camera (within a small
    // epsilon, since the camera's own floating-point state and the
    // server's round-tripped value are never bit-identical): otherwise
    // every URL patch not caused by a camera move (a pure selection
    // change) would re-trigger a pointless `easeTo`/`jumpTo` (issue
    // security-review #2).
    this.handleEvent("set_view", ({z, lat, lng}) => {
      if (this.matchesCurrentView(z, lat, lng)) return

      this.setView(z, lat, lng)
    })

    // Consumed by the LiveView Explore (#016 poses the contract, #017
    // fills it in): a selection fetches and traces the event's relations,
    // a deselection cancels any in-flight fetch and clears them.
    this.handleEvent("event_selected", ({qid}) => {
      this.highlightEvent(qid)
      this.fetchEventLinks(qid)
    })
    this.handleEvent("event_deselected", () => {
      this.highlightEvent(null)
      this.clearEventLinks()
    })

    // Test-only witness (issue #029): `data-e2e-test-api="true"` is only
    // ever rendered by `AmanogawaWeb.ExploreLive` when `config :amanogawa,
    // :expose_e2e_test_api` is `true`, itself only set in `config/
    // test.exs`, so `window.__amanogawaE2E__` never exists outside the E2E
    // suite. It sends the exact same intent a real marker click does
    // (`onMarkerClick`/`onMapClick` above), without depending on WebGL
    // canvas hit-testing under headless Chrome for scenarios that only
    // care about the LiveView/URL/panel contract (the hover and relation
    // lines scenarios still drive the canvas directly, since that IS what
    // they cover).
    if (this.el.dataset.e2eTestApi === "true") {
      window.__amanogawaE2E__ = {
        selectEvent: qid => this.pushEvent("select_event", {qid}),
        deselectEvent: () => this.pushEvent("deselect_event", {})
      }
    }
  },

  setupEventsLayer() {
    if (this.map.getSource(EVENTS_SOURCE_ID)) return

    const tokens = readDesignTokens()

    this.map.addSource(EVENTS_SOURCE_ID, eventsSource())
    this.map.addLayer(
      eventsCircleLayer({
        ...tokens,
        reducedMotion: this.reducedMotion,
        circleColor: this.circleColorExpression(tokens)
      })
    )
    this.map.addLayer(eventsLabelLayer({...tokens, reducedMotion: this.reducedMotion}))
  },

  // The temporal-gradient `circle-color` for `this.previewWindow`, or a
  // plain accent color while no window is known yet (the brief gap
  // between `mounted()` and the first `set_time_window`/drag preview):
  // never a third, hardcoded color, per issue #022's own point d'attention.
  circleColorExpression(tokens) {
    const {from, to} = this.previewWindow
    if (from === null || to === null) return tokens.accentColor

    return mapLibreColorExpression(from, to, tokens.gradientTokens)
  },

  // The `circle-opacity` for `this.previewWindow`: a plain full-visibility
  // constant while no window is known yet (mirroring `circleColorExpression`'s
  // own fallback), the windowed in/out expression otherwise. Shared by the
  // first-load fade-in (`setEventsData`) and every later window update
  // (`updateGradientPaint`) so the two never compute it differently.
  circleOpacityExpression() {
    const {from, to} = this.previewWindow
    if (from === null || to === null) return VISIBLE_OPACITY

    return windowedOpacityExpression(from, to)
  },

  // Re-applies `circle-color` (and, once the first load's fade-in has
  // happened, `circle-opacity`) for `this.previewWindow` on the existing
  // layer: `setPaintProperty`, never a source reload or a layer
  // recreation (issue #022's own point d'attention: MapLibre cannot read
  // CSS custom properties, so the tokens are re-resolved here, but the
  // GeoJSON source data itself is untouched).
  updateGradientPaint() {
    if (!this.map.getLayer(EVENTS_CIRCLE_LAYER_ID)) return

    const tokens = readDesignTokens()
    this.map.setPaintProperty(
      EVENTS_CIRCLE_LAYER_ID,
      "circle-color",
      this.circleColorExpression(tokens)
    )

    if (!this.eventsLoadedOnce) return

    this.map.setPaintProperty(EVENTS_CIRCLE_LAYER_ID, "circle-opacity", this.circleOpacityExpression())
  },

  // Adds the `event-links` source and its line layer below the events
  // layers (`beforeId: EVENTS_CIRCLE_LAYER_ID`), so relation lines never
  // draw over event markers. Must run after `setupEventsLayer/0`, which it
  // always does (`onStyleLoad` calls both, in that order).
  setupLinksLayer() {
    if (this.map.getSource(LINKS_SOURCE_ID)) return

    const {linkColors} = readDesignTokens()

    this.map.addSource(LINKS_SOURCE_ID, linksSource())
    this.map.addLayer(
      linksLineLayer({colors: linkColors, reducedMotion: this.reducedMotion}),
      EVENTS_CIRCLE_LAYER_ID
    )
  },

  // Re-applies the `-transition` paint property of every layer already on
  // the map to match the current `this.reducedMotion`, so a live
  // `prefers-reduced-motion` change (`onMotionChange` above) takes effect
  // on the next fade rather than only after the style next reloads
  // (issue security-review #13). Each layer is checked with `getLayer`
  // first: this can run before `setupEventsLayer`/`setupLinksLayer` have
  // ever added them (a motion preference flip racing the very first
  // `style.load`), in which case there is simply nothing to update yet,
  // the layers will be created with the right transition from the start.
  applyMotionPreference() {
    const transition = fadeTransition(this.reducedMotion)

    if (this.map.getLayer(EVENTS_CIRCLE_LAYER_ID)) {
      this.map.setPaintProperty(EVENTS_CIRCLE_LAYER_ID, "circle-opacity-transition", transition)
    }

    if (this.map.getLayer(EVENTS_LABEL_LAYER_ID)) {
      this.map.setPaintProperty(EVENTS_LABEL_LAYER_ID, "text-opacity-transition", transition)
    }

    if (this.map.getLayer(LINKS_LAYER_ID)) {
      this.map.setPaintProperty(LINKS_LAYER_ID, "line-opacity-transition", transition)
    }
  },

  buildEventsUrl() {
    const bounds = this.map.getBounds()
    const bbox = boundsToBbox({
      west: bounds.getWest(),
      south: bounds.getSouth(),
      east: bounds.getEast(),
      north: bounds.getNorth()
    })

    const params = new URLSearchParams({bbox})
    if (this.timeWindow.from !== null) params.set("from", this.timeWindow.from)
    if (this.timeWindow.to !== null) params.set("to", this.timeWindow.to)

    return `/api/events?${params.toString()}`
  },

  // Fetches the events for the current viewport and time window. Any
  // request still in flight is aborted first, so a slow response can never
  // overwrite a more recent one with stale data. Network errors and
  // aborted requests are silent to the user (logged in development only):
  // the map keeps whatever data it last successfully rendered.
  async fetchEvents() {
    if (this.abortController) this.abortController.abort()

    const controller = new AbortController()
    this.abortController = controller

    try {
      const response = await fetch(this.buildEventsUrl(), {signal: controller.signal})

      if (!response.ok) {
        throw new Error(`events request failed with status ${response.status}`)
      }

      const featureCollection = await response.json()
      this.setEventsData(featureCollection)
    } catch (error) {
      if (error.name === "AbortError") return

      if (process.env.NODE_ENV !== "production") {
        console.error("MapHook: failed to fetch events", error)
      }
    }
  },

  // Updates the events source and, on the first successful load since the
  // layer was (re)created, raises the circle/label opacity from hidden to
  // their target expressions: the `-transition` declared on both layers
  // (`assets/js/map/event_layers.js`) animates that as a fade-in.
  setEventsData(featureCollection) {
    const source = this.map.getSource(EVENTS_SOURCE_ID)
    if (!source) return

    source.setData(featureCollection)

    if (!this.eventsLoadedOnce) {
      this.eventsLoadedOnce = true

      this.map.setPaintProperty(EVENTS_CIRCLE_LAYER_ID, "circle-opacity", this.circleOpacityExpression())
      this.map.setPaintProperty(EVENTS_LABEL_LAYER_ID, "text-opacity", textOpacityExpression())
    }

    this.eventsFetchCount += 1
    this.el.setAttribute("data-events-loaded", "true")
    this.el.setAttribute("data-events-fetch-count", String(this.eventsFetchCount))
  },

  // Whether `z`/`lat`/`lng` already match the current camera, within a
  // small epsilon: `map.getZoom()`/`getCenter()` and the value round-tripped
  // through the LiveView (`AmanogawaWeb.Params.ExploreParams` parses the
  // URL's string params back into floats) are never bit-identical, so an
  // exact `===` comparison would never dedupe a real no-op `set_view`.
  matchesCurrentView(zoom, lat, lng) {
    const center = this.map.getCenter()

    return (
      Math.abs(this.map.getZoom() - zoom) < ZOOM_EPSILON &&
      Math.abs(center.lat - lat) < COORDINATE_EPSILON &&
      Math.abs(center.lng - lng) < COORDINATE_EPSILON
    )
  },

  setView(zoom, lat, lng) {
    this.programmaticMove = true
    const cameraOptions = {center: [lng, lat], zoom}

    if (this.reducedMotion) {
      this.map.jumpTo(cameraOptions)
    } else {
      this.map.easeTo({...cameraOptions, duration: SET_VIEW_EASE_DURATION_MS})
    }
  },

  // Applies the selection highlight through feature-state (the
  // `circle-stroke-width` expression in `event_layers.js`), addressing
  // features by the `qid` promoted as id (`eventsSource`'s `promoteId`).
  // A qid outside the currently loaded viewport, or received before the
  // events source exists yet (a shared link selecting an event right at
  // page load, racing the style's `style.load`), is simply a no-op: there
  // is no feature to highlight, which is fine, the map itself did not
  // move to reveal it.
  highlightEvent(qid) {
    const source = this.map.getSource(EVENTS_SOURCE_ID)
    if (!source) return

    if (this.selectedQid) {
      this.map.setFeatureState({source: EVENTS_SOURCE_ID, id: this.selectedQid}, {selected: false})
    }

    this.selectedQid = qid

    if (qid) {
      this.map.setFeatureState({source: EVENTS_SOURCE_ID, id: qid}, {selected: true})
    }
  },

  clearHoverTimer() {
    if (this.hoverTimer !== null) {
      clearTimeout(this.hoverTimer)
      this.hoverTimer = null
    }
  },

  // Cancels any pending hover delay and in-flight summary fetch, and hides
  // the card immediately: called on marker `mouseleave` and right before a
  // click opens the full event panel, so a stale card never lingers over
  // the newly selected marker.
  clearHoverState() {
    this.hoveringQid = null
    this.clearHoverTimer()
    this.hoverCard.hide()
    if (this.hoverAbortController) this.hoverAbortController.abort()
  },

  // Shows the hover card for `qid` at `point`: served from the client
  // cache when available, otherwise fetched from the summary endpoint
  // (issue #016). Any request still in flight is aborted first. The
  // result is only rendered if the cursor is still over the same feature
  // when the response arrives, since `clearHoverState` clears
  // `hoveringQid` on `mouseleave` but cannot cancel a fetch already
  // resolved on the microtask queue.
  async showHoverCard(qid, point) {
    const cached = this.hoverSummaryCache.get(qid)
    if (cached) {
      this.hoverCard.show(cached, point)
      return
    }

    if (this.hoverAbortController) this.hoverAbortController.abort()

    const controller = new AbortController()
    this.hoverAbortController = controller

    try {
      const response = await fetch(`/api/events/${encodeURIComponent(qid)}/summary`, {
        signal: controller.signal
      })

      if (!response.ok) {
        throw new Error(`event summary request failed with status ${response.status}`)
      }

      const summary = await response.json()
      this.hoverSummaryCache.set(qid, summary)

      if (this.hoveringQid === qid) this.hoverCard.show(summary, point)
    } catch (error) {
      if (error.name === "AbortError") return

      if (process.env.NODE_ENV !== "production") {
        console.error("MapHook: failed to fetch event summary", error)
      }
    }
  },

  // Fetches the typed relations of `qid` (issue #017) and traces them.
  // Any request still in flight is aborted first, so a slow response can
  // never overwrite a more recent selection's lines with stale data.
  async fetchEventLinks(qid) {
    if (this.linksAbortController) this.linksAbortController.abort()

    const controller = new AbortController()
    this.linksAbortController = controller

    try {
      const response = await fetch(`/api/events/${encodeURIComponent(qid)}/links`, {
        signal: controller.signal
      })

      if (!response.ok) {
        throw new Error(`event links request failed with status ${response.status}`)
      }

      const featureCollection = await response.json()
      this.setLinksData(featureCollection)
    } catch (error) {
      if (error.name === "AbortError") return

      if (process.env.NODE_ENV !== "production") {
        console.error("MapHook: failed to fetch event links", error)
      }
    }
  },

  // Replaces the event-links source data and fades it in: opacity is
  // dropped to hidden synchronously, then raised on the next animation
  // frame, so the browser always registers the hidden state first and the
  // `line-opacity-transition` (`assets/js/map/link_layers.js`, skipped
  // entirely under reduced motion) animates every fresh selection's lines
  // in, not just the first one.
  setLinksData(featureCollection) {
    const source = this.map.getSource(LINKS_SOURCE_ID)
    if (!source) return

    if (this.linksOpacityFrame !== null) cancelAnimationFrame(this.linksOpacityFrame)

    this.map.setPaintProperty(LINKS_LAYER_ID, "line-opacity", LINKS_HIDDEN_OPACITY)
    source.setData(featureCollection)

    this.linksOpacityFrame = requestAnimationFrame(() => {
      this.linksOpacityFrame = null
      this.map.setPaintProperty(LINKS_LAYER_ID, "line-opacity", LINKS_VISIBLE_OPACITY)
    })

    // The line layer is a WebGL source, not assertable directly (issue
    // #029's own point d'attention): `data-links-count` is the DOM proxy
    // the E2E suite reads to confirm the relation lines for the CURRENT
    // selection were drawn, and (selecting a second event without an
    // intermediate deselection) that they were *replaced*, not summed
    // with the previous selection's.
    this.el.setAttribute("data-links-count", String(featureCollection.features.length))
  },

  // Cancels any in-flight links fetch and empties the source (issue #017
  // point d'attention: cleanup at deselection is not optional).
  clearEventLinks() {
    if (this.linksAbortController) this.linksAbortController.abort()
    if (this.linksOpacityFrame !== null) {
      cancelAnimationFrame(this.linksOpacityFrame)
      this.linksOpacityFrame = null
    }

    const source = this.map.getSource(LINKS_SOURCE_ID)
    if (!source) return

    this.map.setPaintProperty(LINKS_LAYER_ID, "line-opacity", LINKS_HIDDEN_OPACITY)
    source.setData(emptyLinksFeatureCollection())
    this.el.setAttribute("data-links-count", "0")
  },

  pushMapMoved() {
    const center = this.map.getCenter()

    this.pushEvent(
      "map_moved",
      normalizedMapMovedPayload(this.map.getZoom(), center.lat, center.lng)
    )
  },

  destroyed() {
    this.debouncedFetchEvents.cancel()
    this.debouncedPushMapMoved.cancel()
    if (this.abortController) this.abortController.abort()

    this.clearHoverTimer()
    if (this.hoverAbortController) this.hoverAbortController.abort()
    this.hoverCard.destroy()

    if (this.linksAbortController) this.linksAbortController.abort()
    if (this.linksOpacityFrame !== null) cancelAnimationFrame(this.linksOpacityFrame)

    this.map.off("style.load", this.onStyleLoad)
    this.map.off("moveend", this.onMoveEnd)
    this.map.off("zoomend", this.onZoomEnd)
    this.map.off("click", EVENTS_CIRCLE_LAYER_ID, this.onMarkerClick)
    this.map.off("click", this.onMapClick)
    this.map.off("mouseenter", EVENTS_CIRCLE_LAYER_ID, this.onMarkerEnter)
    this.map.off("mousemove", EVENTS_CIRCLE_LAYER_ID, this.onMarkerMove)
    this.map.off("mouseleave", EVENTS_CIRCLE_LAYER_ID, this.onMarkerLeave)

    this.darkScheme.removeEventListener("change", this.onSchemeChange)
    this.motionQuery.removeEventListener("change", this.onMotionChange)
    window.removeEventListener(TIME_WINDOW_PREVIEW_EVENT, this.onWindowPreview)

    if (this.el.dataset.e2eTestApi === "true") delete window.__amanogawaE2E__

    this.map.remove()
  }
}

export default MapHook
