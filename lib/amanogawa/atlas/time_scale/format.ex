defmodule Amanogawa.Atlas.TimeScale.Format do
  @moduledoc """
  Formats an astronomical year as a timeline axis label (issue #020),
  choosing among three regimes depending on how coarse the current tick
  step is: BP for the deep past, a Roman-numeral century for the
  Antiquity/Middle Ages range, a plain year close to the present. This is
  the authoritative definition of the convention: the JS mirror
  `assets/js/lib/time_format.js` implements the exact same rules, tested
  against the same shared fixture,
  `test/support/fixtures/time_scale/labels.json` (ExUnit here, `node:test`
  on the JS side).

  Unlike `Amanogawa.HistoricalDate.Formatter` (which formats a full
  `HistoricalDate`, honoring its precision), this module formats a bare
  tick **year** picked by `Amanogawa.Atlas.TimeScale.ticks/3`: there is no
  precision to respect here, only the tick step, which tells how coarse a
  label the axis can afford at that zoom level. It shares
  `Amanogawa.HistoricalDate.Formatter.to_roman/1` (Roman numerals) and the
  same astronomical-to-BCE conversion (`year <= 0` becomes `1 - year` "av.
  J.-C."), so the two modules never disagree on how a BCE year reads.

  ## Regimes (checked in this order)

    * tick step `>= 1_000` years and year `<= #{Amanogawa.Atlas.TimeScale.bp_threshold_year()}`
      (the same fixed BP threshold `Amanogawa.Atlas.TimeScale.ticks/3`
      uses): `"N ka BP"`, `N` the year's distance from
      #{Amanogawa.Atlas.TimeScale.bp_epoch()} (the radiocarbon epoch, see
      `Amanogawa.Atlas.TimeScale.bp_epoch/0`) in thousands, rounded.
    * tick step `>= 100` years: a Roman-numeral century, `"VIIIe s. av.
      J.-C."` for a BCE year, `"XIIe s."` for a CE one. The century number
      is `div(display_year, 100) + 1` (`display_year` already converted to
      the 1-indexed BCE/CE scale): consistent with how `TimeScale.ticks/3`
      always hands this branch a year on a round century-or-coarser step,
      so the round tick itself is read as opening the century that follows
      it (tick year `1100` reads `"XIIe s."`, not `"XIe s."`) rather than
      the stricter "which century does this exact year fall in" rule
      `Amanogawa.HistoricalDate.Formatter.format/2` uses for an exact,
      possibly non-round, date. The two conventions agree on every
      non-boundary year (the vast majority); the deliberate difference is
      confined to exact century-boundary ticks, which only this axis-label
      path ever produces.
    * any finer tick step: the plain year, `"1969"` for CE, `"490 av.
      J.-C."` for BCE (same astronomical conversion as above:
      astronomical year `-489` is `490 av. J.-C.`, the Battle of Marathon).

  The format depends only on the *tick step* the caller passes, never on
  an implicit zoom level: the same year can render differently depending
  on how coarse the surrounding graduations are, which is the point (a
  century-scale axis labels its ticks as centuries, a decade-scale axis
  labels the same years individually).
  """

  alias Amanogawa.Atlas.TimeScale
  alias Amanogawa.HistoricalDate.Formatter

  @bp_threshold_year TimeScale.bp_threshold_year()
  @bp_epoch TimeScale.bp_epoch()

  @doc """
  Formats `year` (an astronomical year, `Amanogawa.HistoricalDate`'s
  convention) as an axis label appropriate for `step` (the current tick
  step in years, as returned alongside `Amanogawa.Atlas.TimeScale.ticks/3`
  or computed by the caller from consecutive ticks). Never raises.

  ## Examples

      iex> Amanogawa.Atlas.TimeScale.Format.format_axis_year(-98_050, 1_000)
      "100 ka BP"

      iex> Amanogawa.Atlas.TimeScale.Format.format_axis_year(-750, 100)
      "VIIIe s. av. J.-C."

      iex> Amanogawa.Atlas.TimeScale.Format.format_axis_year(1969, 1)
      "1969"

  """
  @spec format_axis_year(integer(), pos_integer()) :: String.t()
  def format_axis_year(year, step) when step >= 1000 and year <= @bp_threshold_year do
    ka = (@bp_epoch - year) / 1000
    "#{round(ka)} ka BP"
  end

  def format_axis_year(year, step) when step >= 100 do
    {display_year, era} = era_and_display_year(year)
    century = div(display_year, 100) + 1
    with_era("#{Formatter.to_roman(century)}e s.", era)
  end

  def format_axis_year(year, _step) do
    {display_year, era} = era_and_display_year(year)
    with_era(Integer.to_string(display_year), era)
  end

  defp era_and_display_year(year) when year <= 0, do: {1 - year, :bce}
  defp era_and_display_year(year), do: {year, :ce}

  defp with_era(text, :ce), do: text
  defp with_era(text, :bce), do: text <> " av. J.-C."
end
