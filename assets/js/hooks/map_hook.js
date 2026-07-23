// LiveView hook owning the MapLibre map instance. Single concern: render
// the world basemap in light or dark variant following the system theme.
//
// The vendored styles (assets/vendor/map-styles/) are bundled into app.js:
// only tiles, glyphs, and sprites are fetched from the OpenFreeMap origin
// allowed by the Content-Security-Policy.
import maplibregl from "maplibre-gl"

import darkStyle from "../../vendor/map-styles/dark.json"
import lightStyle from "../../vendor/map-styles/light.json"

const INITIAL_CENTER = [0, 20]
const INITIAL_ZOOM = 1.5

const MapHook = {
  mounted() {
    this.darkScheme = window.matchMedia("(prefers-color-scheme: dark)")
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches

    this.map = new maplibregl.Map({
      container: this.el,
      style: this.darkScheme.matches ? darkStyle : lightStyle,
      center: INITIAL_CENTER,
      zoom: INITIAL_ZOOM,
      attributionControl: {compact: true},
      // MapLibre already skips camera easing when the user prefers reduced
      // motion; also disable symbol fade-in so labels appear instantly.
      fadeDuration: reducedMotion ? 0 : 300,
    })

    // setStyle reloads the whole style. Acceptable while the map carries no
    // application data; F03 must re-add its sources and layers after a theme
    // change (styledata event).
    this.onSchemeChange = (event) => {
      this.map.setStyle(event.matches ? darkStyle : lightStyle)
    }

    this.darkScheme.addEventListener("change", this.onSchemeChange)
  },

  destroyed() {
    this.darkScheme.removeEventListener("change", this.onSchemeChange)
    this.map.remove()
  },
}

export default MapHook
