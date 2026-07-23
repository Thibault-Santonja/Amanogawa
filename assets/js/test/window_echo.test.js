import assert from "node:assert/strict"
import {test} from "node:test"

import {createEchoGuard} from "../lib/window_echo.js"

const W1 = {from: -1000, to: 1000}
const W2 = {from: -500, to: 500}
const W3 = {from: -200, to: 200}

// A minimal injectable timer: `fire()` runs the pending callback, as the
// real setTimeout would after `timeoutMs`.
function fakeTimers() {
  let nextId = 1
  const pending = new Map()

  return {
    setTimer(fn, _ms) {
      const id = nextId
      nextId += 1
      pending.set(id, fn)
      return id
    },
    clearTimer(id) {
      pending.delete(id)
    },
    fire() {
      for (const [id, fn] of [...pending]) {
        pending.delete(id)
        fn()
      }
    },
    pendingCount() {
      return pending.size
    }
  }
}

function guardWithTimers() {
  const timers = fakeTimers()
  const guard = createEchoGuard({
    timeoutMs: 1000,
    setTimer: timers.setTimer,
    clearTimer: timers.clearTimer
  })

  return {guard, timers}
}

test("happy path: a server window outside any push burst is applied", () => {
  const {guard} = guardWithTimers()

  assert.equal(guard.shouldApply(W1), true)
})

test("F04 m1 sequence: debounce pushes W2, pointerup pushes W3, the late W2 echo is dropped, the W3 echo settles", () => {
  const {guard} = guardWithTimers()

  // The drag's debounce tick fires first...
  guard.recordPush(W2)
  // ...then pointerup flushes the final window before W2's echo returned.
  guard.recordPush(W3)

  // The stale W2 echo arrives late: dropped, it must not snap the window
  // back to an older state.
  assert.equal(guard.shouldApply(W2), false)

  // The awaited W3 echo arrives: applied, and the guard settles.
  assert.equal(guard.shouldApply(W3), true)

  // Settled: a later, genuinely server-initiated window (back/forward)
  // passes through again.
  assert.equal(guard.shouldApply(W1), true)
})

test("edge case: any different window is dropped while a push is in flight", () => {
  const {guard} = guardWithTimers()

  guard.recordPush(W3)

  assert.equal(guard.shouldApply(W1), false)
  assert.equal(guard.shouldApply(W2), false)
  assert.equal(guard.shouldApply(W3), true)
})

test("edge case: the in-flight state expires after the timeout when the server never echoes", () => {
  const {guard, timers} = guardWithTimers()

  // A pushed window identical to the URL's current state produces no
  // patch, hence no echo: without the timeout, the guard would drop
  // server-initiated windows forever.
  guard.recordPush(W2)
  assert.equal(guard.shouldApply(W1), false)

  timers.fire()

  assert.equal(guard.shouldApply(W1), true)
})

test("edge case: a second push re-arms the timeout instead of stacking timers", () => {
  const {guard, timers} = guardWithTimers()

  guard.recordPush(W2)
  guard.recordPush(W3)

  assert.equal(timers.pendingCount(), 1)
})

test("edge case: dispose cancels the pending timer", () => {
  const {guard, timers} = guardWithTimers()

  guard.recordPush(W2)
  guard.dispose()

  assert.equal(timers.pendingCount(), 0)
})
