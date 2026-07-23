import assert from "node:assert/strict"
import {test} from "node:test"

import {readLabels} from "./hover_card.js"

// A plain object stand-in for the map container DOM element: readLabels
// only ever touches `.dataset`, so no real DOM/document is needed here.

test("happy path: reads the server-rendered label off data-i18n-text-label", () => {
  const container = {dataset: {i18nTextLabel: "Text"}}

  assert.deepEqual(readLabels(container), {text: "Text"})
})

test("edge case: falls back to the French default when the attribute is absent", () => {
  const container = {dataset: {}}

  assert.deepEqual(readLabels(container), {text: "Texte"})
})

test("edge case: falls back to the French default on an empty attribute value", () => {
  const container = {dataset: {i18nTextLabel: ""}}

  assert.deepEqual(readLabels(container), {text: "Texte"})
})
