defmodule Amanogawa.HistoricalDateGenerators do
  @moduledoc """
  Shared StreamData generators for `Amanogawa.HistoricalDate`, used by the
  property-based tests of the historical date model, its Wikidata
  normalization and its formatter. Centralized here so every property test
  exercises the same notion of "a valid historical date".
  """

  use ExUnitProperties

  alias Amanogawa.HistoricalDate

  @doc """
  Generates a valid `%HistoricalDate{}` respecting every invariant of
  `HistoricalDate.changeset/2` (precision-appropriate month/day, in-range
  values).
  """
  @spec historical_date() :: StreamData.t(HistoricalDate.t())
  def historical_date do
    gen all precision <- precision(),
            year <- year(),
            {month, day} <- month_and_day(precision) do
      HistoricalDate.new!(%{year: year, month: month, day: day, precision: precision})
    end
  end

  @doc "Generates a plausible astronomical year, including deep prehistory."
  @spec year() :: StreamData.t(integer())
  def year, do: integer(-200_000..2100)

  @doc "Generates a valid precision on the Wikidata 0-11 scale."
  @spec precision() :: StreamData.t(HistoricalDate.precision())
  def precision, do: integer(0..11)

  defp month_and_day(precision) when precision <= 9, do: constant({nil, nil})

  # Precisions 10 and 11 legitimately occur with missing month/day (a
  # Wikidata statement can promise day precision while only the year is
  # recorded); the generators cover those partial shapes so formatting and
  # round-trip properties exercise them.
  defp month_and_day(10) do
    one_of([constant({nil, nil}), month_only()])
  end

  defp month_and_day(11) do
    one_of([constant({nil, nil}), month_only(), month_and_day()])
  end

  defp month_only do
    gen all month <- integer(1..12) do
      {month, nil}
    end
  end

  defp month_and_day do
    gen all month <- integer(1..12), day <- integer(1..28) do
      {month, day}
    end
  end
end
