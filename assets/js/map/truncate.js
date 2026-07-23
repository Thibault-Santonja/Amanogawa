// Pure text truncation for the hover card extract (issue #016): cuts near
// `maxLength` characters on a word boundary and appends an ellipsis, never
// splitting a word mid-way. No DOM or MapLibre dependency: unit-testable
// with plain node:test.

const DEFAULT_MAX_LENGTH = 200
const ELLIPSIS = "…"

export function truncateExtract(text, maxLength = DEFAULT_MAX_LENGTH) {
  if (!text) return ""
  if (text.length <= maxLength) return text

  const cut = text.slice(0, maxLength)
  const lastSpace = cut.lastIndexOf(" ")
  const trimmed = lastSpace > 0 ? cut.slice(0, lastSpace) : cut

  return `${trimmed.trimEnd()}${ELLIPSIS}`
}
