// DOM component for the map hover card (issue #016): a bubble showing a
// marker's title, truncated extract, thumbnail (when present), and the
// Wikipedia CC BY-SA 4.0 attribution. Built exclusively through
// `createElement`/`textContent` and controlled attributes, never
// `innerHTML`, since the content ultimately comes from a distant Wikipedia
// article (`.claude/rules/security.md`).
//
// The card is `pointer-events-none` (see CARD_CLASS below): it is a
// read-only preview, not an interactive surface. The Wikipedia mention it
// displays is attribution, not a clickable affordance; the interactive,
// fully accessible link (`target="_blank" rel="noopener noreferrer"`)
// lives in the event panel opened on click
// (`AmanogawaWeb.Components.EventPanel`), which sidesteps the
// mouse-leaves-the-marker-before-reaching-the-card race a clickable
// tooltip would introduce.
import {truncateExtract} from "./truncate.js"

const EXTRACT_MAX_LENGTH = 200

const CARD_CLASS =
  "pointer-events-none absolute z-10 w-64 -translate-x-1/2 -translate-y-full rounded-md " +
  "border border-border bg-surface p-2 text-xs text-text shadow-lg transition-opacity " +
  "duration-150 aria-hidden:opacity-0"

// Vertical gap (px) kept between the cursor point and the card, so it
// hovers just above the marker rather than sitting under the pointer.
const CURSOR_OFFSET_PX = 8

// Default label fallbacks, used only if `container` carries no
// `data-i18n-*` attribute at all (defensive: the LiveView always renders
// one, see `AmanogawaWeb.ExploreLive`'s `#map` container).
const DEFAULT_LABELS = {text: "Texte"}

// Reads the server-rendered, translated labels this card needs off
// `container`'s `data-i18n-*` attributes (issue security-review #9: no
// French label hardcoded in JS, `AmanogawaWeb.ExploreLive` renders them
// through `gettext/1` server-side). Exported (rather than an inline
// closure) so this reading/fallback logic is unit-testable with plain
// node:test against a plain `{dataset: {...}}` object, with no real DOM
// element required.
export function readLabels(container) {
  return {
    text: container.dataset.i18nTextLabel || DEFAULT_LABELS.text
  }
}

// Builds the hover card DOM element, appended once to `container` (the map
// container element) and reused for every marker: `show`/`hide` toggle its
// content and visibility, `destroy` removes it from the DOM.
export function createHoverCard(container) {
  const labels = readLabels(container)

  const el = document.createElement("div")
  el.className = CARD_CLASS
  el.setAttribute("role", "tooltip")
  el.setAttribute("aria-hidden", "true")
  container.appendChild(el)

  function hide() {
    el.setAttribute("aria-hidden", "true")
  }

  function reposition(point) {
    el.style.left = `${point.x}px`
    el.style.top = `${point.y - CURSOR_OFFSET_PX}px`
  }

  function show(summary, point) {
    el.replaceChildren(...cardChildren(summary, labels))
    reposition(point)
    el.setAttribute("aria-hidden", "false")
  }

  function destroy() {
    el.remove()
  }

  return {show, hide, reposition, destroy, element: el}
}

function cardChildren(summary, labels) {
  const children = [titleElement(summary.label)]

  if (summary.extract) {
    children.push(extractElement(summary.extract), attributionElement(summary.wiki_url, labels))
  }

  if (summary.thumbnail_url) {
    children.push(thumbnailElement(summary.thumbnail_url, summary.label))
  }

  return children
}

function titleElement(label) {
  const title = document.createElement("p")
  title.className = "font-medium text-text"
  title.textContent = label
  return title
}

function extractElement(extract) {
  const paragraph = document.createElement("p")
  paragraph.className = "mt-1 text-text-muted"
  paragraph.textContent = truncateExtract(extract, EXTRACT_MAX_LENGTH)
  return paragraph
}

function attributionElement(wikiUrl, labels) {
  const paragraph = document.createElement("p")
  paragraph.className = "mt-1 text-text-muted"

  if (wikiUrl) {
    paragraph.append(`${labels.text} : `, wikipediaLink(wikiUrl), ", CC BY-SA 4.0")
  } else {
    paragraph.textContent = `${labels.text} : Wikipédia, CC BY-SA 4.0`
  }

  return paragraph
}

function wikipediaLink(wikiUrl) {
  const link = document.createElement("a")
  link.href = wikiUrl
  link.target = "_blank"
  link.rel = "noopener noreferrer"
  link.textContent = "Wikipédia"
  return link
}

function thumbnailElement(thumbnailUrl, label) {
  const img = document.createElement("img")
  img.className = "mt-1 max-h-24 w-full rounded object-cover"
  img.src = thumbnailUrl
  img.alt = label
  return img
}
