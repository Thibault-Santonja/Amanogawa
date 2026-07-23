import assert from "node:assert/strict"
import {test} from "node:test"

import {debounce} from "./debounce.js"

function wait(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

test("limit case: rapid calls collapse into a single invocation, last argument wins", async () => {
  const calls = []
  const debounced = debounce(value => calls.push(value), 20)

  debounced("first")
  debounced("second")
  debounced("third")

  await wait(40)

  assert.deepEqual(calls, ["third"])
})

test("limit case: calls spaced beyond the delay each fire independently", async () => {
  const calls = []
  const debounced = debounce(value => calls.push(value), 20)

  debounced("first")
  await wait(40)
  debounced("second")
  await wait(40)

  assert.deepEqual(calls, ["first", "second"])
})

test("cancel() prevents a pending call from firing", async () => {
  const calls = []
  const debounced = debounce(value => calls.push(value), 20)

  debounced("first")
  debounced.cancel()

  await wait(40)

  assert.deepEqual(calls, [])
})

test("cancel() is a no-op when no call is pending", () => {
  const debounced = debounce(() => {}, 20)

  assert.doesNotThrow(() => debounced.cancel())
})

test("default delay is applied when none is given", async () => {
  const calls = []
  const debounced = debounce(() => calls.push(true))

  debounced()
  await wait(50)

  assert.deepEqual(calls, [], "250ms default delay should not have elapsed yet")
})
