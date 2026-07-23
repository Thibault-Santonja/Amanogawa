import assert from "node:assert/strict"
import {test} from "node:test"

import {truncateExtract} from "./truncate.js"

test("happy path: a long extract is cut near 200 characters, on a word boundary, with an ellipsis", () => {
  const text =
    "Alexandre le Grand fut roi de Macedoine et conquit un immense empire s etendant jusqu en Inde. "
      .repeat(4)
      .trim()

  const truncated = truncateExtract(text)
  const body = truncated.slice(0, -1)

  assert.ok(truncated.length <= 201)
  assert.ok(truncated.endsWith("…"))
  assert.ok(text.startsWith(body), "the truncated body is an exact prefix of the source text")
  assert.equal(text[body.length], " ", "the cut lands right before a space, never mid-word")
})

test("happy path: a custom maxLength is respected", () => {
  const text = "Bataille de Marathon en Grece antique"
  const truncated = truncateExtract(text, 10)

  assert.ok(truncated.length <= 11)
  assert.ok(truncated.endsWith("…"))
})

test("edge case: a string shorter than maxLength is returned unchanged", () => {
  assert.equal(truncateExtract("Bataille de Marathon"), "Bataille de Marathon")
})

test("edge case: a string exactly at maxLength is returned unchanged", () => {
  const text = "a".repeat(200)

  assert.equal(truncateExtract(text), text)
})

test("edge case: an empty string is returned unchanged", () => {
  assert.equal(truncateExtract(""), "")
})

test("edge case: nullish input returns an empty string", () => {
  assert.equal(truncateExtract(null), "")
  assert.equal(truncateExtract(undefined), "")
})

test("edge case: a single word longer than maxLength is hard-cut without a trailing space", () => {
  const text = "a".repeat(250)

  assert.equal(truncateExtract(text), `${"a".repeat(200)}…`)
})
