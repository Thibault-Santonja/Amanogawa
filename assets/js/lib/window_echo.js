// Anti-echo guard for the timeline's time window (F04 quality finding m1).
//
// The round trip `pushEvent("select_time_window", W)` -> `push_patch` ->
// `handle_params` -> `push_event("set_time_window", W)` echoes every
// pushed window back to the hook. During a burst of pushes (a drag's
// debounce tick W2 followed by the `pointerup` flush W3), a *stale* echo
// (W2) can arrive after the newer push (W3) left, and blindly applying it
// would snap the window back to an older state.
//
// The rule (decided in the F04 review): remember the last window pushed
// (`recordPush`); while a push is in flight, ignore every incoming
// `set_time_window` EXCEPT the one equal to that last pushed window,
// which settles the guard and is applied normally. A genuine
// server-initiated change (browser back/forward) arriving outside a push
// burst passes through untouched, and the in-flight state expires after
// `timeoutMs` as a safety net for the one case the server never echoes at
// all (a pushed window identical to the URL's current state produces no
// patch, hence no echo).
//
// No DOM, no LiveView import: pure and testable under plain `node:test`
// (timers are injectable), exactly like `time_window.js`.

const DEFAULT_TIMEOUT_MS = 1000

export function createEchoGuard({
  timeoutMs = DEFAULT_TIMEOUT_MS,
  setTimer = (fn, ms) => setTimeout(fn, ms),
  clearTimer = id => clearTimeout(id)
} = {}) {
  let lastPushed = null
  let inFlight = false
  let timer = null

  function clearPendingTimer() {
    if (timer !== null) {
      clearTimer(timer)
      timer = null
    }
  }

  function settle() {
    inFlight = false
    clearPendingTimer()
  }

  return {
    // Called right before every `pushEvent("select_time_window", window)`.
    recordPush(window) {
      lastPushed = {...window}
      inFlight = true
      clearPendingTimer()
      timer = setTimer(() => {
        timer = null
        inFlight = false
      }, timeoutMs)
    },

    // Whether an incoming `set_time_window` should be applied. Applying
    // the awaited echo settles the guard as a side effect.
    shouldApply(window) {
      if (!inFlight) return true

      if (lastPushed && window.from === lastPushed.from && window.to === lastPushed.to) {
        settle()
        return true
      }

      return false
    },

    dispose() {
      clearPendingTimer()
    }
  }
}
