// Generic trailing-edge debounce: rapid successive calls collapse into a
// single invocation after `delayMs` of silence, the last call's arguments
// winning. Used by the map hook to throttle `moveend`/`zoomend`-triggered
// fetches and `map_moved` intents (`.claude/rules/liveview.md`).

const DEFAULT_DELAY_MS = 250

export function debounce(fn, delayMs = DEFAULT_DELAY_MS) {
  let timer = null

  function debounced(...args) {
    if (timer !== null) clearTimeout(timer)

    timer = setTimeout(() => {
      timer = null
      fn(...args)
    }, delayMs)
  }

  // Clears a pending call without invoking it: used on hook `destroyed()`
  // so an in-flight debounce timer never fires against a torn-down map.
  debounced.cancel = () => {
    if (timer !== null) {
      clearTimeout(timer)
      timer = null
    }
  }

  return debounced
}
