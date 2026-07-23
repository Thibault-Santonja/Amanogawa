// LiveView hook owning the MapLibre map instance.
//
// Renders the world basemap (light or dark variant following the system
// theme, #005) and the historical events layer (#015): a GeoJSON source
// fetched from `GET /api/events`, styled by data-driven expressions
// (`assets/js/map/event_layers.js`), refetched as the viewport or the time
// window changes. State (the time window, the map view) is owned by the
// LiveView (ADR 0005, issue #018): this hook only renders and reports
// lightweight intents (`map_moved`, later `select_event`), it never holds
// the event list outside the MapLibre source itself.
//
// The vendored styles (assets/vendor/map-styles/) are bundled into app.js:
// only tiles, glyphs, and sprites are fetched from the OpenFreeMap origin
// allowed by the Content-Security-Policy.
import maplibregl from "maplibre-gl"

import {boundsToBbox} from "../map/bbox.js"
import {debounce} from "../map/debounce.js"
import {
  EVENTS_CIRCLE_LAYER_ID,
  EVENTS_LABEL_LAYER_ID,
  EVENTS_SOURCE_ID,
  VISIBLE_OPACITY,
  eventsCircleLayer,
  eventsLabelLayer,
  eventsSource,
  textOpacityExpression
} from "../map/event_layers.js"
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

// Reads the palette tokens the events layer is styled with
// (`assets/css/app.css`): never a hardcoded hex value when a token exists.
function readDesignTokens() {
  const rootStyle = getComputedStyle(document.documentElement)

  return {
    accentColor: rootStyle.getPropertyValue("--palette-accent").trim(),
    haloColor: rootStyle.getPropertyValue("--palette-surface").trim(),
    textColor: rootStyle.getPropertyValue("--palette-text").trim()
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
    this.abortController = null
    this.eventsLoadedOnce = false
    this.selectedQid = null
    // Marks a camera move triggered by `setView` (server-pushed), so the
    // `moveend` it causes is not mistaken for a user-driven move and
    // echoed back to the server as `map_moved` (issue #018 anti-loop
    // guard).
    this.programmaticMove = false

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
      this.eventsLoadedOnce = false
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

    // Selection contract posed here for #016/#017 to build on (issue #018
    // point d'attention): clicking a marker selects it, clicking empty map
    // deselects. `event_selected`/`event_deselected` pushed back by the
    // LiveView only drive the lightweight stroke highlight below, until
    // #016 adds the hover card and event sheet.
    this.onMarkerClick = event => {
      const feature = event.features && event.features[0]
      if (!feature) return

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

    this.onMarkerLeave = () => {
      this.map.getCanvas().style.cursor = ""
    }
    this.map.on("mouseleave", EVENTS_CIRCLE_LAYER_ID, this.onMarkerLeave)

    // setStyle reloads the whole style; re-adding sources and layers after
    // a theme change is handled by `onStyleLoad` above.
    this.onSchemeChange = event => {
      this.map.setStyle(event.matches ? darkStyle : lightStyle)
    }
    this.darkScheme.addEventListener("change", this.onSchemeChange)

    this.onMotionChange = event => {
      this.reducedMotion = event.matches
    }
    this.motionQuery.addEventListener("change", this.onMotionChange)

    // Consumed by the LiveView Explore (#018): a fresh time window pushed
    // from the server always triggers an immediate refetch (not debounced,
    // the client-side drag on the future timeline hook already debounces
    // before pushing).
    this.handleEvent("set_time_window", ({from, to}) => {
      this.timeWindow = {from, to}
      this.fetchEvents()
    })

    // Consumed by the LiveView Explore (#018): a server-pushed camera move
    // (URL navigation, shared link). Flagged as programmatic so the
    // resulting `moveend` is not echoed back as `map_moved`.
    this.handleEvent("set_view", ({z, lat, lng}) => this.setView(z, lat, lng))

    this.handleEvent("event_selected", ({qid}) => this.highlightEvent(qid))
    this.handleEvent("event_deselected", () => this.highlightEvent(null))
  },

  setupEventsLayer() {
    if (this.map.getSource(EVENTS_SOURCE_ID)) return

    const tokens = readDesignTokens()

    this.map.addSource(EVENTS_SOURCE_ID, eventsSource())
    this.map.addLayer(eventsCircleLayer({...tokens, reducedMotion: this.reducedMotion}))
    this.map.addLayer(eventsLabelLayer({...tokens, reducedMotion: this.reducedMotion}))
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
      this.map.setPaintProperty(EVENTS_CIRCLE_LAYER_ID, "circle-opacity", VISIBLE_OPACITY)
      this.map.setPaintProperty(EVENTS_LABEL_LAYER_ID, "text-opacity", textOpacityExpression())
    }
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
  // move to reveal it (that will be #016/#017's concern).
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

  pushMapMoved() {
    const center = this.map.getCenter()

    this.pushEvent("map_moved", {
      z: this.map.getZoom(),
      lat: center.lat,
      lng: center.lng
    })
  },

  destroyed() {
    this.debouncedFetchEvents.cancel()
    this.debouncedPushMapMoved.cancel()
    if (this.abortController) this.abortController.abort()

    this.map.off("style.load", this.onStyleLoad)
    this.map.off("moveend", this.onMoveEnd)
    this.map.off("zoomend", this.onZoomEnd)
    this.map.off("click", EVENTS_CIRCLE_LAYER_ID, this.onMarkerClick)
    this.map.off("click", this.onMapClick)
    this.map.off("mouseenter", EVENTS_CIRCLE_LAYER_ID, this.onMarkerEnter)
    this.map.off("mouseleave", EVENTS_CIRCLE_LAYER_ID, this.onMarkerLeave)

    this.darkScheme.removeEventListener("change", this.onSchemeChange)
    this.motionQuery.removeEventListener("change", this.onMotionChange)

    this.map.remove()
  }
}

export default MapHook
