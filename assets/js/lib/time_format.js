// Formats an astronomical year as a timeline axis label (issue #020).
//
// This is the JS mirror of `Amanogawa.Atlas.TimeScale.Format`
// (`lib/amanogawa/atlas/time_scale/format.ex`), which is the authoritative
// moduledoc for the three regimes below (BP for the deep past, a
// Roman-numeral century for Antiquity/Middle Ages, a plain year close to
// the present) and for the deliberate century-boundary convention (a round
// tick year, e.g. 1100, reads as opening the century that follows it:
// "XIIe s.", not "XIe s."). Both sides are tested against the single
// shared fixture `test/support/fixtures/time_scale/labels.json`
// (`assets/js/test/time_format.test.js` here, ExUnit on the Elixir side).
//
// No dependency, no DOM: pure and testable under plain Node, exactly like
// `time_scale.js`.

import {BP_THRESHOLD_YEAR} from "./time_scale.js"

const BP_EPOCH = 1950

const ROMAN_NUMERALS = [
  [1000, "M"],
  [900, "CM"],
  [500, "D"],
  [400, "CD"],
  [100, "C"],
  [90, "XC"],
  [50, "L"],
  [40, "XL"],
  [10, "X"],
  [9, "IX"],
  [5, "V"],
  [4, "IV"],
  [1, "I"]
]

// Mirrors `Amanogawa.HistoricalDate.Formatter.to_roman/1`: same table,
// same greedy algorithm.
function toRoman(number) {
  let remaining = number
  let roman = ""

  for (const [value, symbol] of ROMAN_NUMERALS) {
    const count = Math.floor(remaining / value)
    roman += symbol.repeat(count)
    remaining -= count * value
  }

  return roman
}

// Astronomical year <= 0 is 1 BCE or earlier: `displayYear = 1 - year`,
// `era = "bce"`. Mirrors `Amanogawa.HistoricalDate.Formatter`'s own
// conversion, so astronomical year -489 reads "490 av. J.-C." (the Battle
// of Marathon) on both sides of the language boundary.
function eraAndDisplayYear(year) {
  return year <= 0 ? {displayYear: 1 - year, era: "bce"} : {displayYear: year, era: "ce"}
}

function withEra(text, era) {
  return era === "bce" ? `${text} av. J.-C.` : text
}

// Formats `year` (an astronomical year) as an axis label appropriate for
// `step` (the current tick step in years). Never throws.
export function formatAxisYear(year, step) {
  if (step >= 1000 && year <= BP_THRESHOLD_YEAR) {
    const ka = (BP_EPOCH - year) / 1000
    return `${Math.round(ka)} ka BP`
  }

  if (step >= 100) {
    const {displayYear, era} = eraAndDisplayYear(year)
    const century = Math.floor(displayYear / 100) + 1
    return withEra(`${toRoman(century)}e s.`, era)
  }

  const {displayYear, era} = eraAndDisplayYear(year)
  return withEra(String(displayYear), era)
}
